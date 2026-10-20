package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"strings"
)

const (
	configFilesFormat = `{{index .Config.Labels "com.docker.compose.project.config_files"}}`
	caddyRoot         = "/data/caddy/pki/authorities/local/root.crt"
	inferenceBundle   = "/etc/understandtech/inference-ca-bundle.pem"
	hostRoots         = "/etc/ssl/certs/ca-certificates.crt"
)

// What the box is in a deployment, and the root certificates of its inference
// links: never an address, which carries the customer's domain.
type Topology struct {
	Role           *string  `json:"role"`
	InferenceRoots []string `json:"inference_roots"`
}

func roleOf(configFiles string) string {
	switch {
	case strings.Contains(configFiles, "compose.compute.yaml"):
		return "compute"
	case strings.Contains(configFiles, "compose.remote-inference.yaml"), strings.Contains(configFiles, "compose.no-gpu.yaml"):
		return "control-plane"
	}
	return "complete"
}

// ut-install writes the bundle as the host's public roots followed by the
// compute node's.
func lastCertificate(bundle string) *x509.Certificate {
	var last *x509.Certificate
	for rest := []byte(bundle); ; {
		block, remaining := pem.Decode(rest)
		if block == nil {
			return last
		}
		if certificate, err := x509.ParseCertificate(block.Bytes); err == nil {
			last = certificate
		}
		rest = remaining
	}
}

func certificateFingerprint(certificate *x509.Certificate) string {
	sum := sha256.Sum256(certificate.Raw)
	return hex.EncodeToString(sum[:])
}

// A bundle that lost the node's root ends with a public one, which every
// control plane shares and would pair boxes that have nothing to do together.
func (m machine) isPublicRoot(root *x509.Certificate) bool {
	public, _ := m.run("", "cat", hostRoots)
	for rest := []byte(public); ; {
		block, remaining := pem.Decode(rest)
		if block == nil {
			return false
		}
		if bytes.Equal(block.Bytes, root.Raw) {
			return true
		}
		rest = remaining
	}
}

func (m machine) inferenceRoot(rows []container, configFiles string) (root *x509.Certificate, linked bool) {
	switch {
	case strings.Contains(configFiles, "compose.compute.yaml"):
		if caddy := runningContainer(rows, "caddy"); caddy != "" {
			content, _ := m.run("", "docker", "exec", caddy, "cat", caddyRoot)
			root = parsePEM(content)
		}
		return root, true
	case strings.Contains(configFiles, "compose.remote-inference.yaml"):
		if api := runningContainer(rows, "api"); api != "" {
			content, _ := m.run("", "docker", "exec", api, "cat", inferenceBundle)
			root = lastCertificate(content)
		}
		if root != nil && m.isPublicRoot(root) {
			root = nil
		}
		return root, true
	}
	return nil, false
}

func (m machine) topology() (Topology, []string) {
	section := Topology{InferenceRoots: []string{}}
	rows := m.containers()
	if len(rows) == 0 {
		return section, []string{"topology-unreadable:role"}
	}
	configFiles, err := m.run("", "docker", "container", "inspect", "-f", configFilesFormat, rows[0].id)
	if err != nil || strings.TrimSpace(configFiles) == "" {
		return section, []string{"topology-unreadable:role"}
	}
	section.Role = optional(roleOf(configFiles))
	root, linked := m.inferenceRoot(rows, configFiles)
	if !linked {
		return section, []string{}
	}
	if root == nil {
		return section, []string{"topology-unreadable:inference-root"}
	}
	section.InferenceRoots = append(section.InferenceRoots, certificateFingerprint(root))
	return section, []string{}
}

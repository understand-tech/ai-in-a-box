package main

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"strings"
)

const (
	configFilesFormat = `{{index .Config.Labels "com.docker.compose.project.config_files"}}`
	linkRoot          = "/data/caddy/pki/authorities/link/root.crt"
	linkedNode        = "/etc/caddy/link.caddy"
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

func certificateFingerprint(certificate *x509.Certificate) string {
	sum := sha256.Sum256(certificate.Raw)
	return hex.EncodeToString(sum[:])
}

// ut-pair writes the node's root into the platform's Caddy settings, as the
// one trust_der of the link; before the pairing, the file is empty.
func linkedNodeRoot(settings string) (root *x509.Certificate, paired bool) {
	for _, line := range strings.Split(settings, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || fields[0] != "trust_der" {
			continue
		}
		der, err := base64.StdEncoding.DecodeString(fields[1])
		if err != nil {
			return nil, true
		}
		root, _ = x509.ParseCertificate(der)
		return root, true
	}
	return nil, false
}

func (m machine) inferenceRoot(rows []container, configFiles string) (root *x509.Certificate, linked bool) {
	caddy := runningContainer(rows, "caddy")
	switch {
	case strings.Contains(configFiles, "compose.compute.yaml"):
		if caddy != "" {
			content, _ := m.run("", "docker", "exec", caddy, "cat", linkRoot)
			root = parsePEM(content)
		}
		return root, true
	case strings.Contains(configFiles, "compose.remote-inference.yaml"):
		if caddy == "" {
			return nil, true
		}
		content, err := m.run("", "docker", "exec", caddy, "cat", linkedNode)
		if err != nil {
			return nil, true
		}
		return linkedNodeRoot(content)
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

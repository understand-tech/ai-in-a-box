package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Box struct {
	Root   []byte    `json:"root"`
	Paired time.Time `json:"paired"`
	From   string    `json:"from,omitempty"`
}

type Node struct {
	Address string    `json:"address"`
	Root    []byte    `json:"root"`
	Paired  time.Time `json:"paired"`
}

type Links struct {
	Admitted []Box `json:"admitted"`
	Node     *Node `json:"node,omitempty"`
	Arbiter  *Node `json:"arbiter,omitempty"`
}

const (
	linksFile         = "links.json"
	admittedBoxesFile = "admitted-boxes.caddy"
	linkedNodeFile    = "linked-node.caddy"
	linkedArbiterFile = "linked-arbiter.caddy"
)

func loadLinks(settings string) (Links, error) {
	var links Links
	data, err := os.ReadFile(filepath.Join(settings, linksFile))
	if errors.Is(err, fs.ErrNotExist) {
		return links, nil
	}
	if err != nil {
		return links, err
	}
	return links, json.Unmarshal(data, &links)
}

func (l Links) admits(root []byte) bool {
	for _, box := range l.Admitted {
		if bytes.Equal(box.Root, root) {
			return true
		}
	}
	return false
}

// Caddy reads the list of admitted boxes as part of its configuration, so that
// a plain reload applies a removal. Without a single box the surface is left
// out entirely: client_auth with no trust pool checks against the system roots,
// and an empty pool is refused, which leaves the previous list in force.
func admittedBoxesCaddyfile(boxes []Box) string {
	if len(boxes) == 0 {
		return ""
	}
	var file strings.Builder
	file.WriteString("(admitted_boxes) {\n\ttrust_pool inline {\n")
	for _, box := range boxes {
		fmt.Fprintf(&file, "\t\ttrust_der %s\n", base64.StdEncoding.EncodeToString(box.Root))
	}
	file.WriteString("\t}\n}\nimport /etc/caddy/link-surface.caddy\n")
	return file.String()
}

func linkedNodeCaddyfile(node *Node) string {
	return relayCaddyfile(node, "linked_node_root", "/etc/caddy/link-relay.caddy")
}

func linkedArbiterCaddyfile(arbiter *Node) string {
	return relayCaddyfile(arbiter, "linked_arbiter_root", "/etc/caddy/arbiter-relay.caddy")
}

func relayCaddyfile(peer *Node, snippet, relay string) string {
	if peer == nil {
		return ""
	}
	return fmt.Sprintf("(%s) {\n\ttls_trust_pool inline {\n\t\ttrust_der %s\n\t}\n}\nimport %s https://%s\n",
		snippet, base64.StdEncoding.EncodeToString(peer.Root), relay, peer.Address)
}

// The two Caddy files are bind-mounted one by one, and such a mount keeps the
// inode it started with: they are rewritten in place, never replaced.
func (l Links) save(settings string) error {
	data, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	for name, content := range map[string]string{
		linksFile:         string(data) + "\n",
		admittedBoxesFile: admittedBoxesCaddyfile(l.Admitted),
		linkedNodeFile:    linkedNodeCaddyfile(l.Node),
		linkedArbiterFile: linkedArbiterCaddyfile(l.Arbiter),
	} {
		if err := os.WriteFile(filepath.Join(settings, name), []byte(content), 0o644); err != nil {
			return err
		}
	}
	return nil
}

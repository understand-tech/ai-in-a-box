package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"os"
	"reflect"
	"testing"
)

func rootCertificate(t *testing.T) (content, fingerprint string) {
	t.Helper()
	written, err := os.ReadFile(receiverCertificate(t))
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(written)
	sum := sha256.Sum256(block.Bytes)
	return string(written), hex.EncodeToString(sum[:])
}

func stackAnswering(configFiles string, more map[string]string) map[string]string {
	answers := map[string]string{
		"docker ps -aq --filter label=com.docker.compose.project.working_dir=/usr/share/understandtech": "aaaa\ngggg\n",
		"docker inspect":           "api running healthy 0 false aaaa\ncaddy running healthy 0 false gggg\n",
		"docker container inspect": configFiles + "\n",
	}
	for command, answer := range more {
		answers[command] = answer
	}
	return answers
}

func checkTopology(t *testing.T, answers map[string]string, role string, roots []string, warnings []string) {
	t.Helper()
	topology, got := machineAnswering(t, answers).topology()
	gotRole := ""
	if topology.Role != nil {
		gotRole = *topology.Role
	}
	if gotRole != role || !reflect.DeepEqual(topology.InferenceRoots, roots) || !reflect.DeepEqual(got, warnings) {
		t.Fatalf("role %q roots %v warnings %v, want %q %v %v", gotRole, topology.InferenceRoots, got, role, roots, warnings)
	}
}

func TestAComputeBoxSendsTheRootOfItsLinkAuthority(t *testing.T) {
	root, fingerprint := rootCertificate(t)
	answers := stackAnswering("/usr/share/understandtech/compose.yaml,/usr/share/understandtech/compose.compute.yaml",
		map[string]string{"docker exec gggg cat /data/caddy/pki/authorities/link/root.crt": root})
	checkTopology(t, answers, "compute", []string{fingerprint}, []string{})
}

func linkedTo(root string) string {
	block, _ := pem.Decode([]byte(root))
	return "(linked_node_root) {\n\ttls_trust_pool inline {\n\t\ttrust_der " + base64.StdEncoding.EncodeToString(block.Bytes) +
		"\n\t}\n}\nimport /etc/caddy/link-relay.caddy https://10.0.0.9:8444\n"
}

func TestAPlatformSendsTheRootOfTheNodeItIsPairedWith(t *testing.T) {
	node, fingerprint := rootCertificate(t)
	answers := stackAnswering("/usr/share/understandtech/compose.yaml,/usr/share/understandtech/compose.remote-inference.yaml",
		map[string]string{"docker exec gggg cat /etc/caddy/link.caddy": linkedTo(node)})
	checkTopology(t, answers, "control-plane", []string{fingerprint}, []string{})
}

func TestAPlatformNotPairedYetHasNoLinkToSend(t *testing.T) {
	answers := stackAnswering("/usr/share/understandtech/compose.yaml,/usr/share/understandtech/compose.remote-inference.yaml",
		map[string]string{"docker exec gggg cat /etc/caddy/link.caddy": ""})
	checkTopology(t, answers, "control-plane", []string{}, []string{})
}

func TestAPlatformWhoseLinkCannotBeReadSaysSo(t *testing.T) {
	answers := stackAnswering("/usr/share/understandtech/compose.yaml,/usr/share/understandtech/compose.remote-inference.yaml", nil)
	checkTopology(t, answers, "control-plane", []string{}, []string{"topology-unreadable:inference-root"})
}

func TestABoxThatServesItselfHasNoInferenceLink(t *testing.T) {
	checkTopology(t, stackAnswering("/usr/share/understandtech/compose.yaml", nil), "complete", []string{}, []string{})
}

func TestAControlPlanePointedElsewhereByHandHasNoLinkToSend(t *testing.T) {
	answers := stackAnswering("/usr/share/understandtech/compose.yaml,/usr/share/understandtech/compose.no-gpu.yaml", nil)
	checkTopology(t, answers, "control-plane", []string{}, []string{})
}

func TestARoleNobodyCouldReadIsNamedNotGuessed(t *testing.T) {
	answers := stackAnswering("", nil)
	delete(answers, "docker container inspect")
	checkTopology(t, answers, "", []string{}, []string{"topology-unreadable:role"})
}

func TestARootNobodyCouldReadIsNamedNotGuessed(t *testing.T) {
	answers := stackAnswering("/usr/share/understandtech/compose.yaml,/usr/share/understandtech/compose.compute.yaml", nil)
	checkTopology(t, answers, "compute", []string{}, []string{"topology-unreadable:inference-root"})
}

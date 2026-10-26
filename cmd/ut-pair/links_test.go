package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeCaddy struct {
	root       []byte
	refuse     bool
	reloads    int
	configured string
}

func (f *fakeCaddy) place(t *testing.T) Place {
	t.Helper()
	settings := t.TempDir()
	return Place{Install: t.TempDir(), Settings: settings, Now: clock, Run: func(_ context.Context, _ string, name string, args ...string) ([]byte, error) {
		command := strings.Join(append([]string{name}, args...), " ")
		switch {
		case strings.HasSuffix(command, "cat "+linkRootInCaddy):
			return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.root}), nil
		case strings.HasSuffix(command, "caddy reload --config /etc/caddy/Caddyfile"):
			f.reloads++
			if f.refuse {
				return nil, errors.New("adapting config: no certificates specified")
			}
			admitted, _ := os.ReadFile(filepath.Join(settings, admittedBoxesFile))
			f.configured = string(admitted)
			return nil, nil
		}
		return nil, errors.New("unexpected: " + command)
	}}
}

func read(t *testing.T, place Place, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(place.Settings, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestNoAdmittedBoxLeavesTheSurfaceOut(t *testing.T) {
	if got := admittedBoxesCaddyfile(nil); got != "" {
		t.Fatalf("with no box: %q", got)
	}
	if got := linkedNodeCaddyfile(nil); got != "" {
		t.Fatalf("with no node: %q", got)
	}
}

func TestEveryAdmittedBoxIsTrustedByItsRootAndNothingElse(t *testing.T) {
	a, b := root(t, "a"), root(t, "b")
	file := admittedBoxesCaddyfile([]Box{{Root: a.Raw}, {Root: b.Raw}})
	for name, der := range map[string][]byte{"a": a.Raw, "b": b.Raw} {
		if !strings.Contains(file, "trust_der "+base64.StdEncoding.EncodeToString(der)+"\n") {
			t.Errorf("%s is not in\n%s", name, file)
		}
	}
	if strings.Count(file, "trust_der") != 2 || !strings.HasSuffix(file, "import /etc/caddy/link-surface.caddy\n") {
		t.Fatalf("written as\n%s", file)
	}
}

func TestTheLinkedNodeIsReachedAtItsAddressAndTrustedByItsRoot(t *testing.T) {
	node := root(t, "node")
	file := linkedNodeCaddyfile(&Node{Address: "10.0.0.9:8444", Root: node.Raw})
	if !strings.Contains(file, "tls_trust_pool inline {\n\t\ttrust_der "+base64.StdEncoding.EncodeToString(node.Raw)+"\n") ||
		!strings.HasSuffix(file, "import /etc/caddy/link-relay.caddy https://10.0.0.9:8444\n") {
		t.Fatalf("written as\n%s", file)
	}
}

func TestAnAdmittedBoxReachesCaddy(t *testing.T) {
	caddy := &fakeCaddy{}
	place := caddy.place(t)
	platform := root(t, "platform")
	if err := place.admit(platform, "10.0.0.5"); err != nil {
		t.Fatal(err)
	}
	if caddy.reloads != 1 || !strings.Contains(caddy.configured, base64.StdEncoding.EncodeToString(platform.Raw)) {
		t.Fatalf("Caddy reloaded %d times with\n%s", caddy.reloads, caddy.configured)
	}
	if err := place.admit(platform, "10.0.0.5"); err != nil || caddy.reloads != 1 {
		t.Fatalf("admitting the same box again: %v, %d reloads", err, caddy.reloads)
	}
}

func TestABoxCaddyRefusesIsNotLeftAdmittedForTheNextRestart(t *testing.T) {
	caddy := &fakeCaddy{}
	place := caddy.place(t)
	first := root(t, "first")
	place.admit(first, "10.0.0.5")
	caddy.refuse = true
	if err := place.admit(root(t, "second"), "10.0.0.6"); err == nil {
		t.Fatal("a refused reload was taken for an admission")
	}
	links, _ := loadLinks(place.Settings)
	if len(links.Admitted) != 1 || strings.Count(read(t, place, admittedBoxesFile), "trust_der") != 1 {
		t.Fatalf("the refused box stayed in the settings:\n%s", read(t, place, admittedBoxesFile))
	}
}

func TestAForgottenBoxIsGoneFromTheList(t *testing.T) {
	caddy := &fakeCaddy{}
	place := caddy.place(t)
	kept, gone := root(t, "kept"), root(t, "gone")
	place.admit(kept, "10.0.0.5")
	place.admit(gone, "10.0.0.6")
	var out bytes.Buffer
	if err := place.forget(fingerprint(gone.Raw)[:12], &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(caddy.configured, base64.StdEncoding.EncodeToString(gone.Raw)) ||
		!strings.Contains(caddy.configured, base64.StdEncoding.EncodeToString(kept.Raw)) {
		t.Fatalf("Caddy runs with\n%s", caddy.configured)
	}
	if err := place.forget(fingerprint(kept.Raw)[:12], &out); err != nil {
		t.Fatal(err)
	}
	if caddy.configured != "" {
		t.Fatalf("with the last box forgotten, Caddy runs with\n%s", caddy.configured)
	}
}

func TestAForgetCaddyRefusesFailsLoudlyAndStaysForTheNextRestart(t *testing.T) {
	caddy := &fakeCaddy{}
	place := caddy.place(t)
	gone := root(t, "gone")
	place.admit(gone, "10.0.0.6")
	caddy.refuse = true
	err := place.forget(fingerprint(gone.Raw)[:12], &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "still serves that box") {
		t.Fatalf("a refused reload: %v", err)
	}
	if read(t, place, admittedBoxesFile) != "" {
		t.Fatal("the forgotten box is back in the settings")
	}
}

func TestForgetNeedsAnUnambiguousFingerprint(t *testing.T) {
	caddy := &fakeCaddy{}
	place := caddy.place(t)
	place.admit(root(t, "a"), "10.0.0.5")
	for _, prefix := range []string{"", "abc", "0000000000000000"} {
		if err := place.forget(prefix, &bytes.Buffer{}); err == nil {
			t.Errorf("forgot something on %q", prefix)
		}
	}
}

func TestTheCodeIsReadFromStandardInputNeverFromTheCommandLine(t *testing.T) {
	caddy := &fakeCaddy{root: root(t, "platform").Raw}
	place := caddy.place(t)
	var out, errs bytes.Buffer
	if status := place.command([]string{"join", "10.0.0.9", code(t).String()}, strings.NewReader(""), &out, &errs); status != 2 {
		t.Fatalf("a code on the command line was taken (%d)", status)
	}
	if err := place.join("10.0.0.9", strings.NewReader("\n"), &out); err == nil || !strings.Contains(err.Error(), "pairing code") {
		t.Fatalf("an empty code: %v", err)
	}
}

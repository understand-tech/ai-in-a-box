package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const token = "pR7xK2mQ9vL4nT8wB3cF6hJ1sD5gA0zE"

func receiverCertificate(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "receiver.example.test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "receiver.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func tokenFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func statusOf(b *box) string {
	_, out := b.call("status")
	decision, _, _ := strings.Cut(out, "\n")
	return decision
}

func TestNothingIsDecidedUntilSomeoneAnswers(t *testing.T) {
	b := newBox(t, nil)
	if got := statusOf(b); got != "Reporting: not decided" {
		t.Fatalf("status = %q", got)
	}
}

func TestANoIsKeptAndSendsNothing(t *testing.T) {
	b := newBox(t, nil)
	if code, out := b.call("configure", "--consent", "no"); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got := statusOf(b); got != "Reporting: off" {
		t.Fatalf("status = %q", got)
	}
}

func TestConfigureRefusesToGuessTheAnswer(t *testing.T) {
	b := newBox(t, nil)
	for _, args := range [][]string{
		{"configure"},
		{"configure", "--consent", "maybe"},
		{"configure", "--consent", "Yes"},
	} {
		if code, _ := b.call(args...); code != 2 {
			t.Fatalf("%v: exit %d, want 2", args, code)
		}
	}
	if _, err := os.Stat(b.place.Settings); !os.IsNotExist(err) {
		t.Fatalf("a refused answer wrote the settings: %v", err)
	}
}

func TestAYesWithEverythingSendsToTheReceiver(t *testing.T) {
	b := newBox(t, nil)
	code, out := b.call("configure", "--consent", "yes",
		"--receiver", "https://receiver.example.test:8444",
		"--token-file", tokenFile(t, token+"\n"),
		"--receiver-cert", receiverCertificate(t))
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got := statusOf(b); got != "Reporting: on, to receiver.example.test:8444, every 15 minutes" {
		t.Fatalf("status = %q", got)
	}
	info, err := os.Stat(b.place.Settings)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("settings mode %v, want 0600", info.Mode().Perm())
	}
	if strings.Contains(out, token) {
		t.Fatal("the token was printed")
	}
}

func TestTheReceiverCanBeGivenAfterTheYes(t *testing.T) {
	b := newBox(t, nil)
	b.call("configure", "--consent", "yes")
	if got := statusOf(b); got != "Reporting: on, waiting for the receiver's address, token and certificate" {
		t.Fatalf("status = %q", got)
	}
	b.call("configure", "--consent", "yes", "--receiver", "https://receiver.example.test:8444")
	b.call("configure", "--consent", "yes", "--token-file", tokenFile(t, token), "--receiver-cert", receiverCertificate(t))
	if got := statusOf(b); got != "Reporting: on, to receiver.example.test:8444, every 15 minutes" {
		t.Fatalf("status = %q", got)
	}
}

func TestANoForgetsTheToken(t *testing.T) {
	b := newBox(t, nil)
	b.call("configure", "--consent", "yes", "--receiver", "https://receiver.example.test:8444",
		"--token-file", tokenFile(t, token), "--receiver-cert", receiverCertificate(t))
	b.call("configure", "--consent", "no")
	content, err := os.ReadFile(b.place.Settings)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(content), token) {
		t.Fatal("the token outlived the no")
	}
}

func TestDetailsThatCannotWorkAreRefused(t *testing.T) {
	b := newBox(t, nil)
	cases := map[string][]string{
		"plain http":         {"--receiver", "http://receiver.example.test:8444"},
		"no host":            {"--receiver", "https://"},
		"empty token":        {"--token-file", tokenFile(t, "\n")},
		"token with a space": {"--token-file", tokenFile(t, "two words")},
		"missing token file": {"--token-file", filepath.Join(t.TempDir(), "absent")},
		"not a certificate":  {"--receiver-cert", tokenFile(t, "not a certificate")},
		"unknown option":     {"--receiver-url", "https://receiver.example.test"},
	}
	for name, extra := range cases {
		args := append([]string{"configure", "--consent", "yes"}, extra...)
		if code, _ := b.call(args...); code == 0 {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := os.Stat(b.place.Settings); !os.IsNotExist(err) {
		t.Fatalf("refused details wrote the settings: %v", err)
	}
}

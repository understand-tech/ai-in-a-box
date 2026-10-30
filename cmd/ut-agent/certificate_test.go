package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Made the way Caddy 2.11 makes its own: an ECDSA root, its key in SEC 1.
func writeAnAuthority(t *testing.T, dir string) *x509.Certificate {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Caddy Local Authority - 2026 ECC Root"},
		NotBefore:             testNow.Add(-time.Hour),
		NotAfter:              testNow.Add(10 * 365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLen:            1,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, _ := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	keyDER, _ := x509.MarshalECPrivateKey(key)
	os.MkdirAll(dir, 0o700)
	os.WriteFile(filepath.Join(dir, "root.crt"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)
	os.WriteFile(filepath.Join(dir, "root.key"), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600)
	root, _ := x509.ParseCertificate(der)
	return root
}

type certifierUnderTest struct {
	Certifier
	volume string
	now    time.Time
}

func newCertifier(t *testing.T, settings string) *certifierUnderTest {
	t.Helper()
	install, volume := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(install, ".env"), []byte(settings), 0o600)
	fake := &fakeBox{answers: map[string]string{"docker volume inspect --format {{.Mountpoint}} ut-caddy-data": volume + "\n"}}
	c := &certifierUnderTest{volume: volume, now: testNow}
	c.Certifier = Certifier{Box: Box{Install: install}, Dir: t.TempDir(), Group: os.Getgid(), Run: fake.run, Now: func() time.Time { return c.now }}
	return c
}

func (c *certifierUnderTest) authority() string {
	return filepath.Join(c.volume, "caddy", "pki", "authorities", "local")
}

func (c *certifierUnderTest) leaf(t *testing.T) *x509.Certificate {
	t.Helper()
	leaf, err := leafOf(c.bundlePath())
	if err != nil {
		t.Fatalf("no certificate written: %v", err)
	}
	return leaf
}

func TestTheConsoleCertificateIsSignedByTheRootBrowsersAlreadyTrust(t *testing.T) {
	c := newCertifier(t, "UT_DOMAIN=\"Box.Example.Test\"\n")
	root := writeAnAuthority(t, c.authority())
	if err := c.keepCurrent(); err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(root)
	leaf := c.leaf(t)
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: "box.example.test", CurrentTime: testNow}); err != nil {
		t.Fatalf("a browser trusting the root would refuse it: %v", err)
	}
	if leaf.NotAfter.Sub(testNow) != certificateLifetime {
		t.Fatalf("it lasts until %v", leaf.NotAfter)
	}
	info, _ := os.Stat(c.bundlePath())
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("the certificate and its key are %v", info.Mode().Perm())
	}
	content, _ := os.ReadFile(c.bundlePath())
	if !bytes.Contains(content, []byte("PRIVATE KEY")) || bytes.Contains(content, mustRead(t, filepath.Join(c.authority(), "root.key"))) {
		t.Fatal("the file holds the wrong key")
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return content
}

func TestACertificateIsRenewedTenDaysBeforeItEnds(t *testing.T) {
	c := newCertifier(t, "UT_DOMAIN=\"box.example.test\"\n")
	writeAnAuthority(t, c.authority())
	c.keepCurrent()
	first := c.leaf(t).SerialNumber
	c.now = testNow.Add(19 * 24 * time.Hour)
	c.keepCurrent()
	if c.leaf(t).SerialNumber.Cmp(first) != 0 {
		t.Fatal("a certificate eleven days from its end was replaced")
	}
	c.now = testNow.Add(21 * 24 * time.Hour)
	c.keepCurrent()
	if c.leaf(t).SerialNumber.Cmp(first) == 0 {
		t.Fatal("a certificate nine days from its end was kept")
	}
}

func TestAnotherRootOrAnotherAddressGetsANewCertificate(t *testing.T) {
	c := newCertifier(t, "UT_DOMAIN=\"box.example.test\"\n")
	writeAnAuthority(t, c.authority())
	c.keepCurrent()
	first := c.leaf(t).SerialNumber
	root := writeAnAuthority(t, c.authority())
	c.keepCurrent()
	if c.leaf(t).CheckSignatureFrom(root) != nil || c.leaf(t).SerialNumber.Cmp(first) == 0 {
		t.Fatal("a box restored with another authority kept a certificate it no longer signs")
	}
	os.WriteFile(filepath.Join(c.Box.Install, ".env"), []byte("UT_DOMAIN=\"ai.example.test\"\n"), 0o600)
	c.keepCurrent()
	if c.leaf(t).VerifyHostname("ai.example.test") != nil {
		t.Fatal("a box moved to another address kept the old name")
	}
}

func TestNoAuthorityNoCertificate(t *testing.T) {
	c := newCertifier(t, "UT_DOMAIN=\"box.example.test\"\nUT_INGRESS_MODE=\"edge\"\n")
	if err := c.keepCurrent(); err == nil {
		t.Fatal("a certificate was claimed with no authority to sign it")
	}
	if _, err := os.Stat(c.bundlePath()); !os.IsNotExist(err) {
		t.Fatalf("something was written: %v", err)
	}
}

func TestAnAddressACertificateCannotCarryIsRefused(t *testing.T) {
	c := newCertifier(t, "UT_DOMAIN=\"box example;test\"\n")
	writeAnAuthority(t, c.authority())
	if err := c.keepCurrent(); err == nil {
		t.Fatal("a certificate was issued for a name that is not one")
	}
}

func TestACertificateOfTheCustomersOwnIsServedAsItIs(t *testing.T) {
	c := newCertifier(t, "UT_DOMAIN=\"box.example.test\"\nUT_INGRESS_MODE=\"custom\"\nUT_CERT_DIR=\"./certs-given\"\n")
	given := filepath.Join(c.Box.Install, "certs-given")
	os.MkdirAll(given, 0o755)
	authority := t.TempDir()
	root := writeAnAuthority(t, authority)
	_, signer, _ := loadAuthority(authority)
	bundle, _ := issue(root, signer, "box.example.test", testNow)
	certificate, _ := pem.Decode(bundle)
	os.WriteFile(filepath.Join(given, "fullchain.pem"), pem.EncodeToMemory(certificate), 0o644)
	os.WriteFile(filepath.Join(given, "privkey.pem"), bundle[len(pem.EncodeToMemory(certificate)):], 0o600)
	if err := c.keepCurrent(); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(c.leaf(t).Raw, certificate.Bytes) {
		t.Fatal("the console serves another certificate than the customer's")
	}
}

package main

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	certificateLifetime = 30 * 24 * time.Hour
	renewWithin         = 10 * 24 * time.Hour
	bundleName          = "tls.pem"
	bundleMode          = 0o640
	certificatesInCaddy = "/etc/caddy/certs"
)

var (
	hostName       = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)
	resourcePrefix = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)
)

// The console's certificate and key, in one file the console reads and never
// writes: a renewal replaces both at once.
type Certifier struct {
	Box   Box
	Dir   string
	Group int
	Run   Runner
	Now   func() time.Time
}

func (c Certifier) bundlePath() string { return filepath.Join(c.Dir, bundleName) }

func keepTheCertificateCurrent(c Certifier, logger *log.Logger) {
	for {
		wait := time.Hour
		if err := c.keepCurrent(); err != nil {
			logger.Printf("the console's certificate: %v", err)
			wait = 10 * time.Minute
		}
		time.Sleep(wait)
	}
}

func (c Certifier) keepCurrent() error {
	domain := strings.ToLower(c.Box.settingOr("UT_DOMAIN", "understand.local"))
	if net.ParseIP(domain) == nil && !hostName.MatchString(domain) {
		return fmt.Errorf("UT_DOMAIN is not a name a certificate can carry")
	}
	if c.Box.setting("UT_INGRESS_MODE") == "custom" {
		return c.copyTheCertificateCaddyServes()
	}
	return c.issueFromTheLocalAuthority(domain)
}

// UT_CERT_FILE and UT_KEY_FILE name paths inside Caddy's container, and
// UT_CERT_DIR is what is mounted there, relative to the install directory as
// compose reads it.
func (c Certifier) onTheHost(inCaddy string) string {
	mounted := c.Box.settingOr("UT_CERT_DIR", "caddy/certs")
	if !filepath.IsAbs(mounted) {
		mounted = filepath.Join(c.Box.Install, mounted)
	}
	if rest, found := strings.CutPrefix(inCaddy, certificatesInCaddy); found {
		return filepath.Join(mounted, rest)
	}
	return inCaddy
}

func (c Certifier) copyTheCertificateCaddyServes() error {
	certificate, err := os.ReadFile(c.onTheHost(c.Box.settingOr("UT_CERT_FILE", certificatesInCaddy+"/fullchain.pem")))
	if err != nil {
		return fmt.Errorf("the certificate Caddy serves cannot be read: %w", err)
	}
	key, err := os.ReadFile(c.onTheHost(c.Box.settingOr("UT_KEY_FILE", certificatesInCaddy+"/privkey.pem")))
	if err != nil {
		return fmt.Errorf("the key Caddy serves cannot be read: %w", err)
	}
	if _, err := tls.X509KeyPair(certificate, key); err != nil {
		return errors.New("the certificate and the key Caddy serves do not go together")
	}
	bundle := append(append(bytes.TrimRight(certificate, "\n"), '\n'), key...)
	if current, err := os.ReadFile(c.bundlePath()); err == nil && bytes.Equal(current, bundle) {
		return nil
	}
	return c.write(bundle)
}

// Found through Docker rather than guessed: its data root is not always
// /var/lib/docker. Caddy itself need not run.
func (c Certifier) localAuthority() (string, error) {
	prefix := c.Box.settingOr("RESOURCE_PREFIX", "ut")
	if !resourcePrefix.MatchString(prefix) {
		return "", errors.New("RESOURCE_PREFIX names no volume")
	}
	volume := prefix + "-caddy-data"
	mount, err := c.Run("", "docker", "volume", "inspect", "--format", "{{.Mountpoint}}", volume)
	if err != nil {
		return "", fmt.Errorf("docker does not show the volume %s: %w", volume, err)
	}
	return filepath.Join(strings.TrimSpace(mount), "caddy", "pki", "authorities", "local"), nil
}

func (c Certifier) issueFromTheLocalAuthority(domain string) error {
	dir, err := c.localAuthority()
	if err != nil {
		return err
	}
	root, signer, err := loadAuthority(dir)
	if err != nil {
		return fmt.Errorf("no local authority in %s — Caddy creates it on its first start in internal mode: %w", dir, err)
	}
	if current, err := leafOf(c.bundlePath()); err == nil && stillGood(current, root, domain, c.Now()) {
		return nil
	}
	bundle, err := issue(root, signer, domain, c.Now())
	if err != nil {
		return err
	}
	return c.write(bundle)
}

func stillGood(leaf, root *x509.Certificate, domain string, now time.Time) bool {
	return leaf.CheckSignatureFrom(root) == nil && leaf.VerifyHostname(domain) == nil && leaf.NotAfter.Sub(now) > renewWithin
}

func firstBlock(path, kind string) ([]byte, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	for block, rest := pem.Decode(content); block != nil; block, rest = pem.Decode(rest) {
		if strings.HasSuffix(block.Type, kind) {
			return block.Bytes, nil
		}
	}
	return nil, fmt.Errorf("%s holds no %s", filepath.Base(path), strings.ToLower(kind))
}

func leafOf(path string) (*x509.Certificate, error) {
	der, err := firstBlock(path, "CERTIFICATE")
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

// Caddy signs its leaves with an intermediate that lives seven days and that
// only a running Caddy renews: a certificate that has to outlive a stopped
// stack is signed by the root, which lasts ten years.
func loadAuthority(dir string) (*x509.Certificate, crypto.Signer, error) {
	root, err := leafOf(filepath.Join(dir, "root.crt"))
	if err != nil {
		return nil, nil, err
	}
	der, err := firstBlock(filepath.Join(dir, "root.key"), "PRIVATE KEY")
	if err != nil {
		return nil, nil, err
	}
	signer, err := parseSigner(der)
	if err != nil {
		return nil, nil, err
	}
	return root, signer, nil
}

func parseSigner(der []byte) (crypto.Signer, error) {
	if key, err := x509.ParseECPrivateKey(der); err == nil {
		return key, nil
	}
	if key, err := x509.ParsePKCS8PrivateKey(der); err == nil {
		if signer, ok := key.(crypto.Signer); ok {
			return signer, nil
		}
	}
	if key, err := x509.ParsePKCS1PrivateKey(der); err == nil {
		return key, nil
	}
	return nil, errors.New("the root key is in no form this agent reads")
}

func issue(root *x509.Certificate, signer crypto.Signer, domain string, now time.Time) ([]byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: domain},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(certificateLifetime),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if ip := net.ParseIP(domain); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{domain}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, root, &key.PublicKey, signer)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})...), nil
}

func (c Certifier) write(bundle []byte) error {
	temporary, err := os.CreateTemp(c.Dir, ".tls-*.pem")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(bundle); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Chown(temporary.Name(), os.Getuid(), c.Group); err != nil {
		return err
	}
	if err := os.Chmod(temporary.Name(), bundleMode); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), c.bundlePath())
}

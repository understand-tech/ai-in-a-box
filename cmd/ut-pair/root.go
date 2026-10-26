package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"time"
)

type Trust struct {
	Own    []byte
	System *x509.CertPool
	Now    func() time.Time
}

// A box is known by the root of its link authority. What comes off the wire is
// parsed, judged, and only its re-encoded DER goes on into Caddy's settings.
func (t Trust) admissibleRoot(der []byte) (*x509.Certificate, error) {
	root, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, errors.New("not a certificate")
	}
	now := t.Now()
	switch {
	case !root.BasicConstraintsValid || !root.IsCA || root.KeyUsage&x509.KeyUsageCertSign == 0:
		return nil, errors.New("not a certificate authority")
	case !bytes.Equal(root.RawIssuer, root.RawSubject) || root.CheckSignatureFrom(root) != nil:
		return nil, errors.New("not a root: it does not sign itself")
	case now.Before(root.NotBefore) || now.After(root.NotAfter):
		return nil, errors.New("a root outside its validity")
	case bytes.Equal(root.Raw, t.Own):
		return nil, errors.New("this box's own root")
	case t.publiclyTrusted(root):
		return nil, errors.New("a public authority, which signs for anyone")
	}
	return root, nil
}

func (t Trust) publiclyTrusted(root *x509.Certificate) bool {
	if t.System == nil {
		return false
	}
	_, err := root.Verify(x509.VerifyOptions{Roots: t.System, CurrentTime: t.Now(), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}})
	return err == nil
}

func fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

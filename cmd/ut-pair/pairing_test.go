package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

func clock() time.Time { return now }

func certificate(t *testing.T, name string, ca bool, parent *x509.Certificate, parentKey *ecdsa.PrivateKey) (*x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(10 * 365 * 24 * time.Hour),
		BasicConstraintsValid: true,
		IsCA:                  ca,
	}
	if ca {
		template.KeyUsage = x509.KeyUsageCertSign | x509.KeyUsageCRLSign
	}
	if parent == nil {
		parent, parentKey = template, key
	}
	der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, parentKey)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return parsed, key
}

func root(t *testing.T, name string) *x509.Certificate {
	t.Helper()
	cert, _ := certificate(t, name, true, nil, nil)
	return cert
}

func code(t *testing.T) Code {
	t.Helper()
	c, err := newCode(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestACodeReadsBackAsTyped(t *testing.T) {
	c := code(t)
	shown := c.String()
	if len(shown) != 24+6+1 || strings.Count(shown, "-") != 6 {
		t.Fatalf("shown as %q", shown)
	}
	for _, typed := range []string{shown, strings.ToLower(shown), strings.ReplaceAll(shown, "-", " "), "  " + strings.ReplaceAll(shown, "-", "") + "\n"} {
		if got, err := parseCode(typed); err != nil || got != c {
			t.Fatalf("%q read as %x, %v", typed, got, err)
		}
	}
}

func TestACodeForgivesTheLettersMistakenForDigits(t *testing.T) {
	var c Code
	c[14] = 1
	shown := c.String()
	if !strings.HasPrefix(shown, "0000-") {
		t.Fatalf("shown as %q", shown)
	}
	if got, err := parseCode("O" + shown[1:]); err != nil || got != c {
		t.Fatalf("an O for a 0 read as %x, %v", got, err)
	}
}

func TestATypoInACodeIsCaught(t *testing.T) {
	shown := code(t).String()
	for i, symbol := range []byte(shown) {
		if symbol == '-' || i == len(shown)-1 {
			continue
		}
		other := byte('0')
		if symbol == '0' {
			other = '1'
		}
		typo := shown[:i] + string(other) + shown[i+1:]
		if _, err := parseCode(typo); err == nil {
			t.Fatalf("%q, one symbol off %q, was taken", typo, shown)
		}
	}
	if _, err := parseCode(shown[:len(shown)-2]); err == nil {
		t.Fatal("a code missing a symbol was taken")
	}
}

func TestASealedMessageOpensOnlyWithItsCodeAndDirection(t *testing.T) {
	c := code(t)
	sealed, err := seal(joining, c, []byte("root"), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if plain, err := open(joining, c, sealed); err != nil || string(plain) != "root" {
		t.Fatalf("opened as %q, %v", plain, err)
	}
	if _, err := open(accepting, c, sealed); err == nil {
		t.Fatal("a join opened as an accept")
	}
	if _, err := open(joining, code(t), sealed); err == nil {
		t.Fatal("opened with another code")
	}
	altered := bytes.Clone(sealed)
	altered[len(altered)-1] ^= 1
	if _, err := open(joining, c, altered); err == nil {
		t.Fatal("an altered message opened")
	}
	again, _ := seal(joining, c, []byte("root"), rand.Reader)
	if bytes.Equal(again[:12], sealed[:12]) {
		t.Fatal("two seals shared a nonce")
	}
}

func TestOnlyAnotherBoxsOwnRootIsAdmissible(t *testing.T) {
	own, other := root(t, "own"), root(t, "other")
	public := root(t, "public")
	system := x509.NewCertPool()
	system.AddCert(public)
	trust := Trust{Own: own.Raw, System: system, Now: clock}
	if _, err := trust.admissibleRoot(other.Raw); err != nil {
		t.Fatalf("another box's root refused: %v", err)
	}
	ca, caKey := certificate(t, "ca", true, nil, nil)
	intermediate, _ := certificate(t, "intermediate", true, ca, caKey)
	notCA, _ := certificate(t, "leaf", false, nil, nil)
	for name, der := range map[string][]byte{
		"garbage":          []byte("MII\n}\nimport evil"),
		"its own root":     own.Raw,
		"a public root":    public.Raw,
		"an intermediate":  intermediate.Raw,
		"not an authority": notCA.Raw,
	} {
		if _, err := trust.admissibleRoot(der); err == nil {
			t.Errorf("%s was admissible", name)
		}
	}
	later := Trust{Own: own.Raw, Now: func() time.Time { return now.Add(11 * 365 * 24 * time.Hour) }}
	if _, err := later.admissibleRoot(other.Raw); err == nil {
		t.Error("an expired root was admissible")
	}
}

type pairing struct {
	node, platform *x509.Certificate
	code           Code
	offer          *Offer
	admitted       []*x509.Certificate
	server         *httptest.Server
}

func newPairing(t *testing.T) *pairing {
	t.Helper()
	p := &pairing{node: root(t, "node"), platform: root(t, "platform"), code: code(t)}
	p.offer = &Offer{
		Code:   p.code,
		Trust:  Trust{Own: p.node.Raw, Now: clock},
		Random: rand.Reader,
		Until:  now.Add(pairingWindow),
		Admit: func(root *x509.Certificate, from string) error {
			p.admitted = append(p.admitted, root)
			return nil
		},
	}
	p.server = httptest.NewServer(p.offer)
	t.Cleanup(p.server.Close)
	return p
}

// The joiner dials the pairing port of the host it is given; the test server
// listens elsewhere, so its requests are rerouted there. Waiting moves the clock.
func (p *pairing) joiner(own *x509.Certificate) Joiner {
	target, _ := url.Parse(p.server.URL)
	return Joiner{
		Trust:  Trust{Own: own.Raw, Now: clock},
		Random: rand.Reader,
		Client: &http.Client{Transport: rewrite{target: target.Host}},
		Wait:   func(d time.Duration) { now = now.Add(d) },
	}
}

type rewrite struct{ target string }

func (r rewrite) RoundTrip(request *http.Request) (*http.Response, error) {
	request.URL.Host = r.target
	return http.DefaultTransport.RoundTrip(request)
}

func (p *pairing) join(t *testing.T, own *x509.Certificate, c Code) (*x509.Certificate, error) {
	t.Helper()
	return p.joiner(own).join(context.Background(), "10.0.0.9:8444", c)
}

func TestAPlatformAndANodeLearnEachOthersRoot(t *testing.T) {
	p := newPairing(t)
	got, err := p.join(t, p.platform, p.code)
	if err != nil || !bytes.Equal(got.Raw, p.node.Raw) {
		t.Fatalf("the platform got %v, %v", got, err)
	}
	if len(p.admitted) != 1 || !bytes.Equal(p.admitted[0].Raw, p.platform.Raw) {
		t.Fatalf("the node admitted %d roots", len(p.admitted))
	}
	select {
	case <-p.offer.Admitted():
	default:
		t.Fatal("the offer did not say it admitted a box")
	}
}

func TestAWrongCodeAdmitsNothing(t *testing.T) {
	p := newPairing(t)
	if _, err := p.join(t, p.platform, code(t)); err == nil || !strings.Contains(err.Error(), "did not take this code") {
		t.Fatalf("joined with another code: %v", err)
	}
	if len(p.admitted) != 0 {
		t.Fatal("a box was admitted on a wrong code")
	}
}

func TestALostAnswerIsAskedAgainButTheCodeAdmitsOneBoxOnly(t *testing.T) {
	p := newPairing(t)
	first, _ := p.join(t, p.platform, p.code)
	second, err := p.join(t, p.platform, p.code)
	if err != nil || !bytes.Equal(first.Raw, second.Raw) || len(p.admitted) != 1 {
		t.Fatalf("asked again: %v, %d admitted", err, len(p.admitted))
	}
	if _, err := p.join(t, root(t, "another platform"), p.code); err == nil || !strings.Contains(err.Error(), "already paired") {
		t.Fatalf("a second box joined on the same code: %v", err)
	}
	if len(p.admitted) != 1 {
		t.Fatal("a second box was admitted")
	}
}

func TestAnAnswerIsResealedEachTime(t *testing.T) {
	p := newPairing(t)
	body := func() []byte {
		var nonce [nonceSize]byte
		sealed, _ := seal(joining, p.code, message(nonce, p.platform.Raw), rand.Reader)
		return sealed
	}
	var replies [][]byte
	for range 2 {
		now = now.Add(time.Second)
		response, err := http.Post(p.server.URL+"/pair", "", bytes.NewReader(body()))
		if err != nil {
			t.Fatal(err)
		}
		var reply bytes.Buffer
		reply.ReadFrom(response.Body)
		response.Body.Close()
		replies = append(replies, reply.Bytes())
	}
	if bytes.Equal(replies[0][:12], replies[1][:12]) {
		t.Fatal("two answers shared a nonce")
	}
}

func TestAnExpiredCodeAdmitsNothing(t *testing.T) {
	p := newPairing(t)
	p.offer.Until = now.Add(-time.Second)
	if _, err := p.join(t, p.platform, p.code); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("joined after the window: %v", err)
	}
}

func TestANodeThatFailsToAdmitLeavesTheCodeUnused(t *testing.T) {
	p := newPairing(t)
	p.offer.Admit = func(*x509.Certificate, string) error { return errors.New("caddy refused") }
	if _, err := p.join(t, p.platform, p.code); err == nil {
		t.Fatal("joined though the node could not admit the box")
	}
	p.offer.Admit = func(root *x509.Certificate, from string) error { p.admitted = append(p.admitted, root); return nil }
	now = now.Add(time.Second)
	if _, err := p.join(t, p.platform, p.code); err != nil {
		t.Fatalf("the code was spent by a failed admission: %v", err)
	}
}

func TestAJoinPlayedBackAsAnAnswerIsRefused(t *testing.T) {
	p := newPairing(t)
	var nonce [nonceSize]byte
	rand.Read(nonce[:])
	reflected, _ := seal(joining, p.code, message(nonce, p.node.Raw), rand.Reader)
	if _, err := p.joiner(p.platform).accepted(reflected, nonce, p.code); err == nil {
		t.Fatal("a join was taken for an answer")
	}
	answer, _ := seal(accepting, p.code, message([nonceSize]byte{1}, p.node.Raw), rand.Reader)
	if _, err := p.joiner(p.platform).accepted(answer, nonce, p.code); err == nil {
		t.Fatal("an answer to another request was taken")
	}
}

func TestANodeSendingItsPlatformsOwnRootBackIsRefused(t *testing.T) {
	p := newPairing(t)
	p.offer.Trust.Own = p.platform.Raw
	if _, err := p.join(t, p.platform, p.code); err == nil {
		t.Fatal("the platform took its own root for the node's")
	}
}

func TestAPlatformCannotPairWithItsOwnRootOnTheNode(t *testing.T) {
	p := newPairing(t)
	if _, err := p.join(t, p.node, p.code); err == nil || !strings.Contains(err.Error(), "refused this box's root") {
		t.Fatalf("the node admitted its own root: %v", err)
	}
}

func TestAnOversizedOrRushedRequestIsTurnedAway(t *testing.T) {
	p := newPairing(t)
	response, err := http.Post(p.server.URL+"/pair", "", bytes.NewReader(make([]byte, maxMessage+1)))
	if err != nil || response.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("an oversized body: %v, %v", response, err)
	}
	response, err = http.Post(p.server.URL+"/pair", "", strings.NewReader("x"))
	if err != nil || response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("a request right after another: %v, %v", response, err)
	}
	now = now.Add(time.Second)
	if response, _ := http.Get(p.server.URL + "/pair"); response.StatusCode != http.StatusNotFound {
		t.Fatalf("a GET answered %d", response.StatusCode)
	}
}

func TestOnlyANameOrAnIPReachesCaddysSettings(t *testing.T) {
	for typed, want := range map[string]string{
		"10.0.0.9":           "10.0.0.9:8444",
		" 10.0.0.9:9444 ":    "10.0.0.9:9444",
		"gpu-2.corp.example": "gpu-2.corp.example:8444",
		"fd00::9":            "[fd00::9]:8444",
		"[fd00::9]:9444":     "[fd00::9]:9444",
	} {
		if got, err := nodeAddress(typed); err != nil || got != want {
			t.Errorf("%q read as %q, %v", typed, got, err)
		}
	}
	for _, typed := range []string{"https://10.0.0.9", "10.0.0.9:0", "node.local", "a b", "gpu}\nimport x", "10.0.0.9:8444/v1", ""} {
		if got, err := nodeAddress(typed); err == nil {
			t.Errorf("%q taken as %q", typed, got)
		}
	}
}

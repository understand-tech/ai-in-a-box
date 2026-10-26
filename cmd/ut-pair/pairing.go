package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	pairingPort   = 8447
	inferencePort = 8444
	pairingWindow = 15 * time.Minute
	maxMessage    = 16 << 10
	// The code is 120 bits: guessing it online is out of reach, so failures
	// never close the window — that would only hand the LAN a way to block it.
	attemptSpacing = 200 * time.Millisecond
)

type Offer struct {
	Code   Code
	Trust  Trust
	Random io.Reader
	Until  time.Time
	// Admit writes the root into Caddy's settings and reloads Caddy; an error
	// leaves the box unadmitted.
	Admit func(root *x509.Certificate, from string) error

	mu          sync.Mutex
	admitted    []byte
	nextAttempt time.Time
	done        chan struct{}
}

func (o *Offer) Admitted() <-chan struct{} {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.done == nil {
		o.done = make(chan struct{})
	}
	return o.done
}

func (o *Offer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/pair" {
		http.NotFound(w, r)
		return
	}
	status, reply := o.answer(w, r)
	w.WriteHeader(status)
	w.Write(reply)
}

func (o *Offer) answer(w http.ResponseWriter, r *http.Request) (int, []byte) {
	o.mu.Lock()
	defer o.mu.Unlock()
	now := o.Trust.Now()
	if now.After(o.Until) {
		return http.StatusGone, nil
	}
	if now.Before(o.nextAttempt) {
		return http.StatusTooManyRequests, nil
	}
	o.nextAttempt = now.Add(attemptSpacing)

	sealed, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxMessage))
	if err != nil {
		return http.StatusRequestEntityTooLarge, nil
	}
	plain, err := open(joining, o.Code, sealed)
	if err != nil {
		return http.StatusForbidden, nil
	}
	nonce, der, err := splitMessage(plain)
	if err != nil {
		return http.StatusForbidden, nil
	}
	root, err := o.Trust.admissibleRoot(der)
	if err != nil {
		return http.StatusUnprocessableEntity, []byte(err.Error())
	}
	switch {
	case o.admitted == nil:
		if err := o.Admit(root, remoteHost(r.RemoteAddr)); err != nil {
			return http.StatusInternalServerError, nil
		}
		o.admitted = root.Raw
		if o.done == nil {
			o.done = make(chan struct{})
		}
		close(o.done)
	case !bytes.Equal(o.admitted, root.Raw):
		return http.StatusConflict, nil
	}
	reply, err := seal(accepting, o.Code, message(nonce, o.Trust.Own), o.Random)
	if err != nil {
		return http.StatusInternalServerError, nil
	}
	return http.StatusOK, reply
}

func remoteHost(address string) string {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return address
	}
	return host
}

type Joiner struct {
	Trust  Trust
	Random io.Reader
	Client *http.Client
	Wait   func(time.Duration)
}

var refusals = map[int]string{
	http.StatusForbidden:           "the node did not take this code: check it against the one the node shows",
	http.StatusConflict:            "this code already paired another box; ask the node for a new one",
	http.StatusGone:                "this code has expired; ask the node for a new one",
	http.StatusUnprocessableEntity: "the node refused this box's root",
	http.StatusInternalServerError: "the node could not admit this box; its own output says why",
}

// The node is reached at the address typed here, never at one it sends back.
func (j Joiner) join(ctx context.Context, node string, code Code) (*x509.Certificate, error) {
	host, _, err := net.SplitHostPort(node)
	if err != nil {
		return nil, err
	}
	var nonce [nonceSize]byte
	if _, err := io.ReadFull(j.Random, nonce[:]); err != nil {
		return nil, err
	}
	body, err := seal(joining, code, message(nonce, j.Trust.Own), j.Random)
	if err != nil {
		return nil, err
	}
	url := "http://" + net.JoinHostPort(host, strconv.Itoa(pairingPort)) + "/pair"
	for attempt := 0; ; attempt++ {
		status, reply, err := j.post(ctx, url, body)
		if err != nil {
			return nil, fmt.Errorf("cannot reach the node at %s: %w", url, err)
		}
		switch {
		case status == http.StatusTooManyRequests && attempt < 50:
			j.Wait(time.Second)
			continue
		case status != http.StatusOK:
			reason, known := refusals[status]
			if !known {
				reason = fmt.Sprintf("the node answered %d", status)
			}
			if detail := strings.TrimSpace(string(reply)); detail != "" && status == http.StatusUnprocessableEntity {
				reason += ": " + detail
			}
			return nil, errors.New(reason)
		}
		return j.accepted(reply, nonce, code)
	}
}

func (j Joiner) accepted(reply []byte, nonce [nonceSize]byte, code Code) (*x509.Certificate, error) {
	plain, err := open(accepting, code, reply)
	if err != nil {
		return nil, errors.New("the answer is not sealed with this code: it does not come from the node")
	}
	echoed, der, err := splitMessage(plain)
	if err != nil || subtle.ConstantTimeCompare(echoed[:], nonce[:]) != 1 {
		return nil, errors.New("the answer belongs to another request")
	}
	root, err := j.Trust.admissibleRoot(der)
	if err != nil {
		return nil, fmt.Errorf("the node's root: %w", err)
	}
	return root, nil
}

func (j Joiner) post(ctx context.Context, url string, body []byte) (int, []byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	response, err := j.Client.Do(request)
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	reply, err := io.ReadAll(io.LimitReader(response.Body, maxMessage))
	return response.StatusCode, reply, err
}

var hostName = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$`)

// What the operator typed ends up in a Caddy file: a name or an IP and an
// optional port, nothing else.
func nodeAddress(typed string) (string, error) {
	typed = strings.TrimSpace(typed)
	host, port := typed, strconv.Itoa(inferencePort)
	if h, p, err := net.SplitHostPort(typed); err == nil {
		host, port = h, p
	}
	if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
		return "", fmt.Errorf("%q: the port is not a number between 1 and 65535", typed)
	}
	if ip := net.ParseIP(host); ip == nil {
		switch {
		case !hostName.MatchString(host) || len(host) > 253:
			return "", fmt.Errorf("%q is neither an IP nor a host name", typed)
		case strings.HasSuffix(strings.ToLower(host), ".local"):
			return "", fmt.Errorf("%s: this box's containers cannot resolve a .local name; give the node's IP or a DNS name", host)
		}
	}
	return net.JoinHostPort(host, port), nil
}

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type deposit struct {
	path, authorization, checksum string
	body                          []byte
}

type fakeReceiver struct {
	server   *httptest.Server
	mu       sync.Mutex
	deposits []deposit
	answers  []int
}

func newFakeReceiver(t *testing.T, answers ...int) *fakeReceiver {
	t.Helper()
	receiver := &fakeReceiver{answers: answers}
	receiver.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		receiver.mu.Lock()
		receiver.deposits = append(receiver.deposits, deposit{r.URL.Path, r.Header.Get("Authorization"), r.Header.Get("X-Report-Sha256"), body})
		status := http.StatusCreated
		if len(receiver.answers) > 0 {
			status, receiver.answers = receiver.answers[0], receiver.answers[1:]
		}
		receiver.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		message := "kept"
		if status != http.StatusCreated {
			message = "report.release: not an allowed value"
		}
		fmt.Fprintf(w, `{"status": %d, "message": %q}`, status, message)
	}))
	t.Cleanup(receiver.server.Close)
	return receiver
}

func (r *fakeReceiver) received() []deposit {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]deposit(nil), r.deposits...)
}

type box struct {
	place Place
	clock time.Time
}

func newBox(t *testing.T, receiver *fakeReceiver) *box {
	t.Helper()
	dir := t.TempDir()
	b := &box{clock: time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)}
	b.place = Place{
		Settings: filepath.Join(dir, "etc", "reporting.json"),
		State:    filepath.Join(dir, "var", "reporting"),
		Now:      func() time.Time { return b.clock },
		Timeout:  2 * time.Second,
	}
	if receiver != nil {
		certificate := filepath.Join(dir, "receiver.pem")
		pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: receiver.server.Certificate().Raw})
		if err := os.WriteFile(certificate, pemBytes, 0o644); err != nil {
			t.Fatal(err)
		}
		b.must(t, "configure", "--consent", "yes", "--receiver", receiver.server.URL,
			"--token-file", tokenFile(t, token), "--receiver-cert", certificate)
	}
	return b
}

func (b *box) call(args ...string) (int, string) {
	var out bytes.Buffer
	code := runIn(args, b.place, &out, &out)
	return code, out.String()
}

func (b *box) must(t *testing.T, args ...string) string {
	t.Helper()
	code, out := b.call(args...)
	if code != 0 {
		t.Fatalf("%v: exit %d: %s", args, code, out)
	}
	return out
}

func (b *box) enqueue(t *testing.T, kind, content string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "payload")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	b.must(t, "enqueue", kind, path)
}

func (b *box) waiting(t *testing.T) int {
	t.Helper()
	items, err := listQueue(queueDir(b.place.State))
	if err != nil {
		t.Fatal(err)
	}
	return len(items)
}

func digest(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func TestAnAcceptedReportLeavesTheQueueWithTheHeadersTheReceiverReads(t *testing.T) {
	receiver := newFakeReceiver(t)
	b := newBox(t, receiver)
	b.enqueue(t, "report", `{"schema": 3}`)
	b.enqueue(t, "usage", "gzip bytes")
	b.must(t, "send")

	got := receiver.received()
	if len(got) != 2 {
		t.Fatalf("%d deposits, want 2", len(got))
	}
	if got[0].path != "/reports" || got[1].path != "/conso" {
		t.Fatalf("paths %q, %q", got[0].path, got[1].path)
	}
	for _, d := range got {
		if d.authorization != "Bearer "+token {
			t.Fatalf("authorization %q", d.authorization)
		}
		if d.checksum != digest(d.body) {
			t.Fatalf("checksum %q does not match the body", d.checksum)
		}
	}
	if b.waiting(t) != 0 {
		t.Fatal("accepted deposits are still queued")
	}
}

func TestWhatTheReceiverCouldNotTakeIsSentAgainNextTime(t *testing.T) {
	receiver := newFakeReceiver(t, http.StatusServiceUnavailable)
	b := newBox(t, receiver)
	b.enqueue(t, "report", `{"schema": 3}`)
	b.must(t, "send")
	if b.waiting(t) != 1 {
		t.Fatal("a refused deposit left the queue")
	}
	b.clock = b.clock.Add(time.Hour)
	b.must(t, "send")
	if b.waiting(t) != 0 || len(receiver.received()) != 2 {
		t.Fatalf("not sent again: %d waiting, %d deposits", b.waiting(t), len(receiver.received()))
	}
}

func TestOneRefusedReportDoesNotHoldBackTheOthers(t *testing.T) {
	receiver := newFakeReceiver(t, http.StatusUnprocessableEntity)
	b := newBox(t, receiver)
	b.enqueue(t, "report", `{"schema": 3, "release": "a b"}`)
	b.clock = b.clock.Add(time.Minute)
	b.enqueue(t, "report", `{"schema": 3}`)
	b.must(t, "send")
	if b.waiting(t) != 1 || len(receiver.received()) != 2 {
		t.Fatalf("%d waiting, %d deposits", b.waiting(t), len(receiver.received()))
	}
	if status := b.must(t, "status"); !strings.Contains(status, "report.release: not an allowed value") {
		t.Fatalf("the receiver's reason is not shown: %q", status)
	}
}

func TestARevokedTokenStopsSendingUntilANewOneIsGiven(t *testing.T) {
	receiver := newFakeReceiver(t, http.StatusUnauthorized)
	b := newBox(t, receiver)
	b.enqueue(t, "report", `{"schema": 3}`)
	b.enqueue(t, "usage", "gzip bytes")
	b.must(t, "send")
	if len(receiver.received()) != 1 {
		t.Fatalf("%d deposits after a 401, want 1", len(receiver.received()))
	}
	b.must(t, "send")
	if len(receiver.received()) != 1 {
		t.Fatal("a revoked token kept sending")
	}
	if status := b.must(t, "status"); !strings.Contains(status, "revoked") {
		t.Fatalf("status does not say revoked: %q", status)
	}
	b.must(t, "configure", "--consent", "yes", "--token-file", tokenFile(t, "a"+token[1:]))
	b.must(t, "send")
	if b.waiting(t) != 0 {
		t.Fatal("a new token did not resume sending")
	}
}

func TestADepositOlderThanAWeekIsGivenUp(t *testing.T) {
	receiver := newFakeReceiver(t)
	b := newBox(t, receiver)
	b.enqueue(t, "report", `{"schema": 3}`)
	b.clock = b.clock.Add(maxAge + time.Minute)
	b.must(t, "send")
	if b.waiting(t) != 0 || len(receiver.received()) != 0 {
		t.Fatalf("%d waiting, %d deposits", b.waiting(t), len(receiver.received()))
	}
	if status := b.must(t, "status"); !strings.Contains(status, "1 given up") {
		t.Fatalf("status does not count what was given up: %q", status)
	}
}

func TestTheQueueKeepsTheNewestWithinItsSize(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	items := []Item{
		{Name: "a", Created: now.Add(-3 * time.Hour), Size: 40},
		{Name: "b", Created: now.Add(-2 * time.Hour), Size: 40},
		{Name: "c", Created: now.Add(-1 * time.Hour), Size: 40},
	}
	keep, drop := prune(items, now, 100, maxAge)
	if len(keep) != 2 || keep[0].Name != "b" || keep[1].Name != "c" || len(drop) != 1 || drop[0].Name != "a" {
		t.Fatalf("keep %v drop %v", keep, drop)
	}
}

func TestAReceiverOutOfReachLeavesEverythingQueued(t *testing.T) {
	receiver := newFakeReceiver(t)
	b := newBox(t, receiver)
	receiver.server.Close()
	b.enqueue(t, "report", `{"schema": 3}`)
	b.must(t, "send")
	if b.waiting(t) != 1 {
		t.Fatal("an unreachable receiver emptied the queue")
	}
	if status := b.must(t, "status"); !strings.Contains(status, "unreachable") {
		t.Fatalf("status does not say unreachable: %q", status)
	}
}

func TestAReceiverThatNeverAnswersDoesNotHoldThePass(t *testing.T) {
	release := make(chan struct{})
	slow := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	t.Cleanup(func() { close(release); slow.Close() })
	b := newBox(t, &fakeReceiver{server: slow})
	b.place.Timeout = 300 * time.Millisecond
	b.enqueue(t, "report", `{"schema": 3}`)
	started := time.Now()
	b.must(t, "send")
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("the pass waited %v", elapsed)
	}
	if b.waiting(t) != 1 {
		t.Fatal("a deposit with no answer left the queue")
	}
}

func TestTwoPassesNeverSendTogether(t *testing.T) {
	receiver := newFakeReceiver(t)
	b := newBox(t, receiver)
	b.enqueue(t, "report", `{"schema": 3}`)
	unlock, err := lockState(b.place.State)
	if err != nil {
		t.Fatal(err)
	}
	b.must(t, "send")
	unlock()
	if len(receiver.received()) != 0 {
		t.Fatal("a second pass sent while the first held the lock")
	}
}

func TestNothingIsQueuedOrSentWithoutAYes(t *testing.T) {
	b := newBox(t, nil)
	path := filepath.Join(t.TempDir(), "payload")
	os.WriteFile(path, []byte(`{"schema": 3}`), 0o644)
	if code, _ := b.call("enqueue", "report", path); code == 0 {
		t.Fatal("queued with no answer given")
	}
	b.must(t, "configure", "--consent", "no")
	if code, _ := b.call("enqueue", "report", path); code == 0 {
		t.Fatal("queued after a no")
	}
}

func TestOnlyTheTwoKindsTheReceiverTakesCanBeQueued(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	path := filepath.Join(t.TempDir(), "payload")
	os.WriteFile(path, []byte("x"), 0o644)
	if code, _ := b.call("enqueue", "logs", path); code == 0 {
		t.Fatal("an unknown kind was queued")
	}
}

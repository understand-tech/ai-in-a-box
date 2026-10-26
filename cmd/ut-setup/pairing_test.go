package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakePair struct {
	mu     sync.Mutex
	calls  [][]string
	stdins []string
	lines  []string
	fail   bool
}

func (f *fakePair) run(_ context.Context, args []string, stdin string, said func(string)) error {
	f.mu.Lock()
	f.calls = append(f.calls, args)
	f.stdins = append(f.stdins, stdin)
	lines, fail := f.lines, f.fail
	f.mu.Unlock()
	for _, line := range lines {
		said(line)
	}
	if fail {
		return errors.New("ut-pair exited with 1")
	}
	return nil
}

const shown = "7KQ2-M9XD-0000-1111-2222-3333-U"

var offered = []string{"On the platform, until 14:35:", "", "  sudo ut-pair join <this machine's address>", "", "and give it this code:", "", "  " + shown, "", "This node's root: ab12", "Admitted the box from 10.0.0.5, root cd34"}

func installedAs(t *testing.T, form url.Values, pair *fakePair) *box {
	t.Helper()
	b := newBox(t, &fakeInstall{})
	b.wizard.pairer = pair.run
	b.signIn()
	if status := b.answer(form).StatusCode; status != http.StatusAccepted {
		t.Fatalf("the install answered %d", status)
	}
	b.waitForTheEnd()
	return b
}

func computeAnswers() url.Values {
	return url.Values{"role": {"compute"}, "compute_address": {"10.0.0.12"}, "license": {"k"}, "reporting": {"no"}}
}

func platformAnswers() url.Values {
	return url.Values{"role": {"platform"}, "domain": {"box.example.com"}, "node_address": {"10.0.0.12"}, "license": {"k"}, "reporting": {"no"}}
}

func (b *box) pairing() Pairing {
	b.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var pairing Pairing
	for time.Now().Before(deadline) {
		response := b.get("/pairing")
		json.NewDecoder(response.Body).Decode(&pairing)
		response.Body.Close()
		if !pairing.Running {
			return pairing
		}
		time.Sleep(10 * time.Millisecond)
	}
	return pairing
}

func TestAComputeNodeShowsTheCodeUtPairOffers(t *testing.T) {
	pair := &fakePair{lines: offered}
	b := installedAs(t, computeAnswers(), pair)
	if status := b.post("/offer", nil, b.server.URL).StatusCode; status != http.StatusAccepted {
		t.Fatalf("the offer answered %d", status)
	}
	pairing := b.pairing()
	if pairing.Code != shown || pairing.Until != "14:35" || pairing.Paired != "10.0.0.5, root cd34" || pairing.Problem != "" {
		t.Fatalf("read as %+v", pairing)
	}
	if len(pair.calls) != 1 || strings.Join(pair.calls[0], " ") != "offer" {
		t.Fatalf("ut-pair called with %v", pair.calls)
	}
}

func TestOnlyAComputeNodeOffersACode(t *testing.T) {
	pair := &fakePair{lines: offered}
	b := installedAs(t, platformAnswers(), pair)
	if status := b.post("/offer", nil, b.server.URL).StatusCode; status != http.StatusConflict {
		t.Fatalf("a platform's offer answered %d", status)
	}
	if len(pair.calls) != 0 {
		t.Fatal("ut-pair ran on a platform")
	}
}

func TestAnExpiredOfferSaysWhy(t *testing.T) {
	pair := &fakePair{lines: []string{"  " + shown, "ut-pair: no platform paired before the code expired"}, fail: true}
	b := installedAs(t, computeAnswers(), pair)
	b.post("/offer", nil, b.server.URL)
	if pairing := b.pairing(); pairing.Problem != "no platform paired before the code expired" || pairing.Paired != "" {
		t.Fatalf("read as %+v", pairing)
	}
}

func TestAPlatformPairsWithTheNodeItNamedAndTheCodeIsNeverAnArgument(t *testing.T) {
	pair := &fakePair{lines: []string{"Linked to the node at 10.0.0.12:8444, root ab12"}}
	b := installedAs(t, platformAnswers(), pair)
	response := b.post("/pair", url.Values{"code": {" " + shown + " "}}, b.server.URL)
	var pairing Pairing
	json.NewDecoder(response.Body).Decode(&pairing)
	if response.StatusCode != http.StatusOK || pairing.Paired != "10.0.0.12:8444, root ab12" {
		t.Fatalf("answered %d, %+v", response.StatusCode, pairing)
	}
	if strings.Join(pair.calls[0], " ") != "join 10.0.0.12" || pair.stdins[0] != shown+"\n" {
		t.Fatalf("ut-pair called with %v, given %q", pair.calls, pair.stdins)
	}
	if strings.Contains(strings.Join(pair.calls[0], " "), shown) {
		t.Fatal("the code was on ut-pair's command line")
	}
}

func TestARefusedPairingSaysWhatUtPairSaid(t *testing.T) {
	pair := &fakePair{lines: []string{"ut-pair: the node did not take this code: check it against the one the node shows"}, fail: true}
	b := installedAs(t, platformAnswers(), pair)
	response := b.post("/pair", url.Values{"code": {shown}}, b.server.URL)
	said, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusUnprocessableEntity || !strings.Contains(string(said), "did not take this code") {
		t.Fatalf("answered %d: %s", response.StatusCode, said)
	}
}

func TestOnlyAPlatformJustInstalledPairsAndNotWithoutItsSession(t *testing.T) {
	pair := &fakePair{}
	b := installedAs(t, computeAnswers(), pair)
	if status := b.post("/pair", url.Values{"code": {shown}}, b.server.URL).StatusCode; status != http.StatusConflict {
		t.Fatalf("a compute node's pairing answered %d", status)
	}
	stranger := newBox(t, &fakeInstall{})
	stranger.wizard.pairer = pair.run
	if status := stranger.post("/pair", url.Values{"code": {shown}}, stranger.server.URL).StatusCode; status != http.StatusForbidden {
		t.Fatalf("a pairing without the session answered %d", status)
	}
	if len(pair.calls) != 0 {
		t.Fatal("ut-pair ran")
	}
}

package main

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"
)

const joinTimeout = 3 * time.Minute

type Pairer func(ctx context.Context, args []string, stdin string, said func(string)) error

type Pairing struct {
	Running bool   `json:"running"`
	Code    string `json:"code"`
	Until   string `json:"until"`
	Paired  string `json:"paired"`
	Problem string `json:"problem"`
}

var (
	shownCode  = regexp.MustCompile(`^\s*([0-9A-Z]{4}(-[0-9A-Z]{4}){5}-[0-9A-Z*~$=])\s*$`)
	shownUntil = regexp.MustCompile(`until ([0-9]{2}:[0-9]{2})`)
)

func (p Pairing) read(line string) Pairing {
	if found := shownCode.FindStringSubmatch(line); found != nil {
		p.Code = found[1]
	}
	if found := shownUntil.FindStringSubmatch(line); found != nil {
		p.Until = found[1]
	}
	if at := strings.Index(line, "Admitted the box from "); at >= 0 {
		p.Paired = strings.TrimPrefix(line[at:], "Admitted the box from ")
	}
	if at := strings.Index(line, "ut-pair: "); at >= 0 {
		p.Problem = strings.TrimPrefix(line[at:], "ut-pair: ")
	}
	return p
}

func (w *Wizard) isComputeNode() bool {
	w.mu.Lock()
	compute := w.progress.Succeeded && w.progress.Compute
	w.mu.Unlock()
	installed := w.installed()
	return compute || (installed != nil && installed.Role == "compute")
}

// The code is kept here, for the page that asked for it, and goes nowhere else:
// ut-pair prints it on its own output, never in a log.
func (w *Wizard) offer(rw http.ResponseWriter, _ *http.Request) {
	if !w.isComputeNode() {
		http.Error(rw, "only a compute node shows a pairing code", http.StatusConflict)
		return
	}
	w.pairingMu.Lock()
	if w.pairing.Running {
		w.pairingMu.Unlock()
		http.Error(rw, "a code is already shown", http.StatusConflict)
		return
	}
	w.pairing = Pairing{Running: true}
	w.pairingMu.Unlock()
	go func() {
		err := w.pairer(context.Background(), []string{"offer"}, "", func(line string) {
			w.recordPairing(func(p Pairing) Pairing { return p.read(line) })
		})
		w.recordPairing(func(p Pairing) Pairing {
			p.Running = false
			if err != nil && p.Problem == "" {
				p.Problem = "ut-pair stopped; sudo ut-pair offer in a terminal says why"
			}
			return p
		})
	}()
	rw.WriteHeader(http.StatusAccepted)
}

func (w *Wizard) recordPairing(change func(Pairing) Pairing) {
	w.pairingMu.Lock()
	defer w.pairingMu.Unlock()
	w.pairing = change(w.pairing)
}

func (w *Wizard) reportPairing(rw http.ResponseWriter, _ *http.Request) {
	w.pairingMu.Lock()
	pairing := w.pairing
	w.pairingMu.Unlock()
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(pairing)
}

// The code reaches ut-pair on its standard input, never on its command line,
// where any process of the box could read it.
func (w *Wizard) pair(rw http.ResponseWriter, r *http.Request) {
	w.mu.Lock()
	node := ""
	if w.progress.Succeeded && w.progress.Platform {
		node = w.progress.Node
	}
	w.mu.Unlock()
	if node == "" {
		http.Error(rw, "only a platform just installed to take its inference from a compute node pairs here", http.StatusConflict)
		return
	}
	code := strings.TrimSpace(r.PostFormValue("code"))
	if code == "" || len(code) > 64 || strings.ContainsAny(code, "\r\n") {
		http.Error(rw, "the code is the 24 letters and digits the compute node shows, in groups of four, and one more", http.StatusUnprocessableEntity)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), joinTimeout)
	defer cancel()
	var result Pairing
	err := w.pairer(ctx, []string{"join", node}, code+"\n", func(line string) {
		result = result.read(line)
		if at := strings.Index(line, "Linked to the node at "); at >= 0 {
			result.Paired = strings.TrimPrefix(line[at:], "Linked to the node at ")
		}
	})
	if err != nil || result.Paired == "" {
		problem := result.Problem
		if problem == "" {
			problem = "the pairing stopped; sudo ut-pair join " + node + " in a terminal says why"
		}
		http.Error(rw, problem, http.StatusUnprocessableEntity)
		return
	}
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(result)
}

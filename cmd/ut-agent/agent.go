package main

import (
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	maxLogLines   = 500
	maxNoteBytes  = 1024
	whoHeader     = "X-UT-Who"
	unknownCaller = "unknown"
)

var (
	consoleActions = []string{"sign-in", "sign-out"}
	consoleResults = []string{"ok", "refused", "locked"}
)

// Everything the console may ask, and nothing else: no action here writes
// anything on the box but the activity itself.
type Agent struct {
	box      Box
	run      Runner
	activity *Activity
	now      func() time.Time
	space    spaceReader
}

func newAgent(box Box, run Runner, activity *Activity, now func() time.Time) *Agent {
	return &Agent{box: box, run: run, activity: activity, now: now, space: statfsReader}
}

func (a *Agent) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	rw.Header().Set("Cache-Control", "no-store")
	switch r.Method + " " + r.URL.Path {
	case "GET /v1/status":
		a.status(rw, r)
	case "GET /v1/logs":
		a.logs(rw, r)
	case "GET /v1/activity":
		a.readActivity(rw, r)
	case "POST /v1/activity":
		a.noteActivity(rw, r)
	default:
		a.refuse(rw, r, printable(r.Method+" "+r.URL.Path, maxDetailLength))
	}
}

func caller(r *http.Request) string {
	if who := r.Header.Get(whoHeader); accountName.MatchString(who) {
		return who
	}
	return unknownCaller
}

func (a *Agent) record(who, action, result, detail string) {
	line := Line{At: a.now().UTC().Format(time.RFC3339), Who: who, Action: action, Result: result, Detail: detail}
	if err := a.activity.note(line); err != nil {
		log.Printf("ut-agent: the activity cannot be written: %v", err)
	}
}

// The reason goes to the activity, for the operator; the caller is told no
// more than that it was refused.
func (a *Agent) refuse(rw http.ResponseWriter, r *http.Request, reason string) {
	a.record(caller(r), "refused", "refused", reason)
	http.Error(rw, "refused", http.StatusForbidden)
}

func onlyParameters(query url.Values, names ...string) bool {
	if len(query) != len(names) {
		return false
	}
	for _, name := range names {
		if len(query[name]) != 1 {
			return false
		}
	}
	return true
}

func boundedCount(text string, limit int) (int, bool) {
	n, err := strconv.Atoi(text)
	return n, err == nil && n >= 1 && n <= limit && strconv.Itoa(n) == text
}

func (a *Agent) services() ([]string, error) {
	output, err := a.run(a.box.Install, "docker", "compose", "config", "--services")
	if err != nil {
		return nil, err
	}
	return strings.Fields(output), nil
}

func (a *Agent) logs(rw http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	if !onlyParameters(query, "service", "lines") {
		a.refuse(rw, r, "GET /v1/logs: parameters other than service and lines")
		return
	}
	lines, ok := boundedCount(query.Get("lines"), maxLogLines)
	if !ok {
		a.refuse(rw, r, "GET /v1/logs: lines outside 1 to 500")
		return
	}
	services, err := a.services()
	if err != nil {
		http.Error(rw, "the services of this box cannot be listed", http.StatusServiceUnavailable)
		return
	}
	service := query.Get("service")
	if !slices.Contains(services, service) {
		a.refuse(rw, r, "GET /v1/logs: a service this box does not run")
		return
	}
	output, err := a.run(a.box.Install, "docker", "compose", "logs", "--no-color", "--timestamps", "--tail", strconv.Itoa(lines), service)
	if err != nil {
		a.record(caller(r), "read-logs", "failed", service)
		http.Error(rw, "docker compose logs failed", http.StatusBadGateway)
		return
	}
	a.record(caller(r), "read-logs", "ok", service)
	rw.Header().Set("Content-Type", "text/plain; charset=utf-8")
	rw.Write([]byte(output))
}

func (a *Agent) readActivity(rw http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	if !onlyParameters(query, "limit") {
		a.refuse(rw, r, "GET /v1/activity: parameters other than limit")
		return
	}
	limit, ok := boundedCount(query.Get("limit"), maxActivityLimit)
	if !ok {
		a.refuse(rw, r, "GET /v1/activity: limit outside 1 to 200")
		return
	}
	lines, err := a.activity.last(limit)
	if err != nil {
		http.Error(rw, "the activity cannot be read", http.StatusInternalServerError)
		return
	}
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(lines)
}

type Note struct {
	Who    string `json:"who"`
	Action string `json:"action"`
	Result string `json:"result"`
}

func (n Note) valid() bool {
	return accountName.MatchString(n.Who) && slices.Contains(consoleActions, n.Action) && slices.Contains(consoleResults, n.Result)
}

func (a *Agent) noteActivity(rw http.ResponseWriter, r *http.Request) {
	decoder := json.NewDecoder(http.MaxBytesReader(rw, r.Body, maxNoteBytes))
	decoder.DisallowUnknownFields()
	var note Note
	if decoder.Decode(&note) != nil || decoder.More() || !note.valid() {
		a.refuse(rw, r, "POST /v1/activity: not a line the console writes")
		return
	}
	a.record(note.Who, note.Action, note.Result, "")
	rw.WriteHeader(http.StatusNoContent)
}

func (a *Agent) status(rw http.ResponseWriter, r *http.Request) {
	if len(r.URL.Query()) != 0 {
		a.refuse(rw, r, "GET /v1/status: parameters")
		return
	}
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(a.collect())
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

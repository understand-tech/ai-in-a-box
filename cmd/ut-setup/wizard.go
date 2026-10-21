package main

import (
	"context"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	sessionCookie = "ut-setup"
	maxFailures   = 5
)

//go:embed page
var page embed.FS

type Installer func(ctx context.Context, args []string, line func(string)) error

type Wizard struct {
	installer Installer
	hosts     map[string]bool
	stop      chan string

	mu       sync.Mutex
	code     string
	session  string
	failures int
	progress Progress
	served   bool
	stopped  bool

	checking  sync.Once
	readiness Readiness

	listing sync.Once
	models  []Model
}

type Model struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

// ut-install --list-models prints one model a line, the name --model takes
// first; the lines it logs start with their level in brackets.
func modelsListed(lines []string) []Model {
	models := []Model{}
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 0 || strings.HasPrefix(line, "[") {
			continue
		}
		models = append(models, Model{ID: fields[0], Label: strings.Join(fields, " ")})
	}
	return models
}

type Readiness struct {
	Ready bool     `json:"ready"`
	Lines []string `json:"lines"`
}

func newWizard(installer Installer, code, session string, hosts ...string) *Wizard {
	allowed := map[string]bool{}
	for _, host := range hosts {
		allowed[host] = true
	}
	return &Wizard{installer: installer, hosts: allowed, stop: make(chan string, 1), code: code, session: session}
}

func (w *Wizard) Stopped() <-chan string { return w.stop }

func (w *Wizard) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", w.start)
	mux.HandleFunc("POST /enter", w.enter)
	mux.Handle("GET /page/", http.FileServerFS(page))
	mux.HandleFunc("POST /install", w.withSession(w.install))
	mux.HandleFunc("GET /progress", w.withSession(w.report))
	mux.HandleFunc("GET /check", w.withSession(w.check))
	mux.HandleFunc("GET /models", w.withSession(w.listModels))
	mux.HandleFunc("POST /secrets", w.withSession(w.secrets))
	return w.guarded(mux)
}

// A page another site opens can still reach 127.0.0.1, and a name it controls
// can resolve there: only requests that name this server are answered.
func (w *Wizard) guarded(next http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		rw.Header().Set("Cache-Control", "no-store")
		rw.Header().Set("X-Frame-Options", "DENY")
		rw.Header().Set("Content-Security-Policy", "default-src 'self'")
		rw.Header().Set("Referrer-Policy", "no-referrer")
		if !w.hosts[r.Host] {
			http.Error(rw, "not this address", http.StatusMisdirectedRequest)
			return
		}
		if r.Method == http.MethodPost && r.Header.Get("Origin") != "http://"+r.Host {
			http.Error(rw, "refused", http.StatusForbidden)
			return
		}
		next.ServeHTTP(rw, r)
	})
}

// Browsers load an address before it is opened — typed in the bar, or shown
// as a preview — and not always with the cookies they keep. Showing the
// address spends nothing: the code is spent by the click that posts it.
func (w *Wizard) start(rw http.ResponseWriter, r *http.Request) {
	w.mu.Lock()
	defer w.mu.Unlock()
	switch {
	case w.hasSession(r) && r.URL.RawQuery != "":
		http.Redirect(rw, r, "/", http.StatusSeeOther)
	case w.hasSession(r):
		http.ServeFileFS(rw, r, page, "page/index.html")
	case r.URL.Query().Get("code") != "":
		http.ServeFileFS(rw, r, page, "page/enter.html")
	default:
		http.Error(rw, "Open the address ut-setup printed on the box.", http.StatusForbidden)
	}
}

func (w *Wizard) enter(rw http.ResponseWriter, r *http.Request) {
	w.mu.Lock()
	defer w.mu.Unlock()
	code := r.PostFormValue("code")
	if w.code == "" || subtle.ConstantTimeCompare([]byte(code), []byte(w.code)) != 1 {
		w.refuse(rw)
		return
	}
	w.code = ""
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: w.session, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
	rw.WriteHeader(http.StatusNoContent)
}

func (w *Wizard) withSession(next http.HandlerFunc) http.HandlerFunc {
	return func(rw http.ResponseWriter, r *http.Request) {
		w.mu.Lock()
		allowed := w.hasSession(r)
		if !allowed {
			if _, err := r.Cookie(sessionCookie); err == nil {
				w.refuse(rw)
			} else {
				http.Error(rw, "Open the address ut-setup printed on the box.", http.StatusForbidden)
			}
		}
		w.mu.Unlock()
		if allowed {
			next(rw, r)
		}
	}
}

func (w *Wizard) hasSession(r *http.Request) bool {
	cookie, err := r.Cookie(sessionCookie)
	return err == nil && w.code == "" && subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(w.session)) == 1
}

// Called with mu held. Past maxFailures nothing is answered any more: the
// operator sees why on the box and starts ut-setup again for a new code.
func (w *Wizard) refuse(rw http.ResponseWriter) {
	w.failures++
	if w.failures >= maxFailures {
		w.halt("refused too many wrong codes — run ut-setup again for a new one")
	}
	http.Error(rw, "Open the address ut-setup printed on the box.", http.StatusForbidden)
}

func (w *Wizard) halt(reason string) {
	if w.stopped {
		return
	}
	w.stopped = true
	w.stop <- reason
}

func (w *Wizard) install(rw http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(rw, "unreadable form", http.StatusBadRequest)
		return
	}
	answers, err := parseAnswers(r.PostForm)
	if err != nil {
		http.Error(rw, err.Error(), http.StatusUnprocessableEntity)
		return
	}

	if answers.Model != "" && !w.lists(answers.Model) {
		http.Error(rw, "the model is not one this box lists", http.StatusUnprocessableEntity)
		return
	}

	w.mu.Lock()
	if w.progress.Running || w.progress.Succeeded {
		w.mu.Unlock()
		http.Error(rw, "an install is already running", http.StatusConflict)
		return
	}
	w.progress = Progress{Running: true, Domain: answers.Domain, started: time.Now()}
	w.mu.Unlock()

	license, err := writeLicense(answers.License)
	if err != nil {
		w.record(func(p Progress) Progress { return p.read("[fail] " + err.Error()).finish(false) })
		http.Error(rw, "the license key could not be kept for ut-install", http.StatusInternalServerError)
		return
	}
	go func() {
		err := w.installer(context.Background(), installArguments(answers, license), func(line string) {
			w.record(func(p Progress) Progress { return p.read(line) })
		})
		os.Remove(license)
		w.record(func(p Progress) Progress { return p.finish(err == nil) })
	}()
	rw.WriteHeader(http.StatusAccepted)
}

// ut-install --check changes nothing and takes a few seconds: it runs once,
// the first time the page asks, and its answer is kept for every reload.
func (w *Wizard) check(rw http.ResponseWriter, _ *http.Request) {
	w.checking.Do(func() {
		var lines []string
		err := w.installer(context.Background(), []string{"--check"}, func(line string) { lines = append(lines, line) })
		w.readiness = Readiness{Ready: err == nil, Lines: lines}
	})
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(w.readiness)
}

func (w *Wizard) modelsHere() []Model {
	w.listing.Do(func() {
		var lines []string
		err := w.installer(context.Background(), []string{"--list-models"}, func(line string) { lines = append(lines, line) })
		w.models = []Model{}
		if err == nil {
			w.models = modelsListed(lines)
		}
	})
	return w.models
}

func (w *Wizard) lists(id string) bool {
	for _, model := range w.modelsHere() {
		if model.ID == id {
			return true
		}
	}
	return false
}

func (w *Wizard) listModels(rw http.ResponseWriter, _ *http.Request) {
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(w.modelsHere())
}

func (w *Wizard) record(change func(Progress) Progress) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.progress = change(w.progress)
}

func (w *Wizard) report(rw http.ResponseWriter, _ *http.Request) {
	w.mu.Lock()
	progress := w.progress
	progress.Lines = append([]string{}, progress.Lines...)
	progress.Steps = append([]string{}, progress.Steps...)
	progress.Warnings = append([]string{}, progress.Warnings...)
	if !progress.started.IsZero() {
		progress.Elapsed = int(time.Since(progress.started).Seconds())
	}
	w.mu.Unlock()
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(progress)
}

func (w *Wizard) secrets(rw http.ResponseWriter, _ *http.Request) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.progress.Succeeded || w.served {
		http.Error(rw, "nothing to show", http.StatusGone)
		return
	}
	settings, err := os.ReadFile(w.progress.secrets)
	if err != nil {
		http.Error(rw, "the settings ut-install wrote could not be read — the passwords are in local.env", http.StatusInternalServerError)
		return
	}
	w.served = true
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(readSecrets(string(settings)))
	w.halt("install complete, secrets shown")
}

func writeLicense(license string) (string, error) {
	file, err := os.CreateTemp("", "ut-setup-license-*")
	if err != nil {
		return "", err
	}
	defer file.Close()
	if _, err := file.WriteString(license + "\n"); err != nil {
		os.Remove(file.Name())
		return "", err
	}
	return file.Name(), nil
}

package main

import (
	"context"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"net/http"
	"os"
	"sync"
	"time"
)

const (
	sessionCookie = "ut-setup"
	maxFailures   = 5
)

//go:embed page
var page embed.FS

type Installer func(ctx context.Context, args []string, said func(string), happened func(Event)) error

type Wizard struct {
	installer Installer
	folder    Folder
	hosts     map[string]bool
	stop      chan string

	mu       sync.Mutex
	code     string
	session  string
	failures int
	progress Progress
	served   bool
	stopped  bool

	checking  sync.Mutex
	readiness Readiness

	listing sync.Mutex
	listed  bool
	models  []Model
}

type Model struct {
	ID             string `json:"id"`
	Served         string `json:"served"`
	Size           string `json:"size"`
	License        string `json:"license"`
	RunsItsOwnCode bool   `json:"runs_its_own_code"`
}

type Readiness struct {
	Ready             bool          `json:"ready"`
	Messages          []Message     `json:"messages"`
	FromFolder        bool          `json:"from_folder"`
	LicenseFromFolder bool          `json:"license_from_folder"`
	Installed         *Installation `json:"installed"`
}

// What ut-install --check found already installed: settings and versions, no
// key and no password.
type Installation struct {
	Role             string `json:"role"`
	Address          string `json:"address"`
	Node             string `json:"node"`
	Model            string `json:"model"`
	ReportingDecided bool   `json:"reporting_decided"`
	Licensed         bool   `json:"licensed"`
	Installed        string `json:"installed"`
	Release          string `json:"release"`
}

func installationFrom(event Event) *Installation {
	return &Installation{event.Role, event.Address, event.Node, event.Model, event.Reporting, event.Licensed, event.Installed, event.Release}
}

func newWizard(installer Installer, folder Folder, code, session string, hosts ...string) *Wizard {
	allowed := map[string]bool{}
	for _, host := range hosts {
		allowed[host] = true
	}
	return &Wizard{installer: installer, folder: folder, hosts: allowed, stop: make(chan string, 1), code: code, session: session}
}

func (w *Wizard) run(args []string, said func(string), happened func(Event)) error {
	return w.installer(context.Background(), append(w.folder.arguments(), args...), said, happened)
}

func (w *Wizard) Stopped() <-chan string { return w.stop }

func (w *Wizard) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", w.start)
	mux.HandleFunc("POST /enter", w.enter)
	mux.Handle("GET /page/", http.FileServerFS(page))
	mux.HandleFunc("POST /install", w.withSession(w.install))
	mux.HandleFunc("POST /update", w.withSession(w.update))
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

func (w *Wizard) update(rw http.ResponseWriter, _ *http.Request) {
	installed := w.installed()
	if installed == nil {
		http.Error(rw, "nothing is installed here to update", http.StatusConflict)
		return
	}
	w.mu.Lock()
	if w.progress.Running || w.progress.Succeeded {
		w.mu.Unlock()
		http.Error(rw, "an install is already running", http.StatusConflict)
		return
	}
	w.progress = Progress{Running: true, Update: true, Domain: installed.Address, started: time.Now()}
	w.mu.Unlock()
	go func() {
		err := w.run(nil, func(line string) {
			w.record(func(p Progress) Progress { return p.read(line) })
		}, func(event Event) {
			w.record(func(p Progress) Progress { return p.apply(event) })
		})
		w.record(func(p Progress) Progress { return p.finish(err == nil) })
	}()
	rw.WriteHeader(http.StatusAccepted)
}

func (w *Wizard) installed() *Installation {
	w.checking.Lock()
	defer w.checking.Unlock()
	return w.readiness.Installed
}

// Answers would be passed as options and replace what the box runs with: an
// installed box is updated as it is, and its settings change in a terminal.
func (w *Wizard) install(rw http.ResponseWriter, r *http.Request) {
	if w.installed() != nil {
		http.Error(rw, "this box is already installed: update it, or change a setting with ut-install in a terminal", http.StatusConflict)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(rw, "unreadable form", http.StatusBadRequest)
		return
	}
	answers, err := parseAnswers(r.PostForm, w.folder)
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
	if answers.Role == "compute" {
		w.progress = Progress{Running: true, Compute: true, Domain: answers.ComputeAddress, started: time.Now()}
	}
	w.mu.Unlock()

	license := ""
	if w.folder.License == "" {
		license, err = writeLicense(answers.License)
		if err != nil {
			w.record(func(p Progress) Progress { return p.apply(Event{Event: "fail", Text: err.Error()}).finish(false) })
			http.Error(rw, "the license key could not be kept for ut-install", http.StatusInternalServerError)
			return
		}
	}
	go func() {
		err := w.run(installArguments(answers, license), func(line string) {
			w.record(func(p Progress) Progress { return p.read(line) })
		}, func(event Event) {
			w.record(func(p Progress) Progress { return p.apply(event) })
		})
		if license != "" {
			os.Remove(license)
		}
		w.record(func(p Progress) Progress { return p.finish(err == nil) })
	}()
	rw.WriteHeader(http.StatusAccepted)
}

// ut-install --check changes nothing and takes a few seconds: a box found ready
// is not checked again, and one that was not is checked on every reload, so what
// the operator fixed in between shows.
func (w *Wizard) check(rw http.ResponseWriter, _ *http.Request) {
	w.checking.Lock()
	if !w.readiness.Ready {
		messages := []Message{}
		var installed *Installation
		err := w.run([]string{"--check"}, func(string) {}, func(event Event) {
			if event.Event == "installed" {
				installed = installationFrom(event)
			}
			messages = told(messages, event)
		})
		w.readiness = Readiness{Ready: err == nil, Messages: messages, FromFolder: w.folder.Images != "", LicenseFromFolder: w.folder.License != "", Installed: installed}
	}
	readiness := w.readiness
	w.checking.Unlock()
	rw.Header().Set("Content-Type", "application/json")
	json.NewEncoder(rw).Encode(readiness)
}

func (w *Wizard) modelsHere() []Model {
	w.listing.Lock()
	defer w.listing.Unlock()
	if !w.listed {
		listed := []Model{}
		err := w.run([]string{"--list-models"}, func(string) {}, func(event Event) {
			if event.Event == "model" {
				listed = append(listed, Model{ID: event.ID, Served: event.Served, Size: event.Size, License: event.License, RunsItsOwnCode: event.RunsItsOwnCode})
			}
		})
		w.models, w.listed = []Model{}, err == nil
		if w.listed {
			w.models = listed
		}
	}
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
	progress.Messages = append([]Message{}, progress.Messages...)
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

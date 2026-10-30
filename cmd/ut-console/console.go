package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	sessionCookie  = "__Host-ut-console"
	account        = "admin"
	idleLimit      = 15 * time.Minute
	sessionLimit   = 8 * time.Hour
	maxFailures    = 5
	lockedFor      = 15 * time.Minute
	agentTimeout   = 90 * time.Second
	maxAgentAnswer = 4 << 20
	maxFormBytes   = 4096
	whoHeader      = "X-UT-Who"
	policy         = "default-src 'self'; frame-ancestors 'none'"
)

//go:embed page
var page embed.FS

type session struct {
	started, seen time.Time
}

func (s session) over(now time.Time) bool {
	return now.Sub(s.seen) > idleLimit || now.Sub(s.started) > sessionLimit
}

type Console struct {
	host         string
	agent        *http.Client
	agentURL     string
	passwordFile string
	now          func() time.Time

	checking sync.Mutex

	mu          sync.Mutex
	sessions    map[string]session
	failures    int
	lockedUntil time.Time
}

func newConsole(host string, agent *http.Client, agentURL, passwordFile string, now func() time.Time) *Console {
	return &Console{host: host, agent: agent, agentURL: agentURL, passwordFile: passwordFile, now: now, sessions: map[string]session{}}
}

func (c *Console) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", c.start)
	mux.Handle("GET /page/", http.FileServerFS(page))
	mux.HandleFunc("POST /sign-in", c.signIn)
	mux.HandleFunc("POST /sign-out", c.withSession(c.signOut))
	mux.HandleFunc("GET /api/status", c.withSession(c.relay("/v1/status")))
	mux.HandleFunc("GET /api/logs", c.withSession(c.relay("/v1/logs", "service", "lines")))
	mux.HandleFunc("GET /api/activity", c.withSession(c.relay("/v1/activity", "limit")))
	return c.guarded(mux)
}

// A page another site opens can still reach this port, and a name it controls
// can resolve to this box: only requests that name this console are answered.
func (c *Console) guarded(next http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		rw.Header().Set("Cache-Control", "no-store")
		rw.Header().Set("Content-Security-Policy", policy)
		rw.Header().Set("X-Frame-Options", "DENY")
		rw.Header().Set("X-Content-Type-Options", "nosniff")
		rw.Header().Set("Referrer-Policy", "no-referrer")
		if r.Host != c.host {
			http.Error(rw, "not this address", http.StatusMisdirectedRequest)
			return
		}
		if r.Method == http.MethodPost && r.Header.Get("Origin") != "https://"+r.Host {
			http.Error(rw, "refused", http.StatusForbidden)
			return
		}
		next.ServeHTTP(rw, r)
	})
}

func (c *Console) start(rw http.ResponseWriter, r *http.Request) {
	if c.signedIn(r) {
		http.ServeFileFS(rw, r, page, "page/index.html")
		return
	}
	http.ServeFileFS(rw, r, page, "page/sign-in.html")
}

func (c *Console) signedIn(r *http.Request) bool {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	open, found := c.sessions[cookie.Value]
	if !found {
		return false
	}
	now := c.now()
	if open.over(now) {
		delete(c.sessions, cookie.Value)
		return false
	}
	open.seen = now
	c.sessions[cookie.Value] = open
	return true
}

func (c *Console) withSession(next http.HandlerFunc) http.HandlerFunc {
	return func(rw http.ResponseWriter, r *http.Request) {
		if !c.signedIn(r) {
			http.Error(rw, "Sign in again.", http.StatusUnauthorized)
			return
		}
		next(rw, r)
	}
}

func (c *Console) note(ctx context.Context, action, result string) error {
	body, _ := json.Marshal(map[string]string{"who": account, "action": action, "result": result})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.agentURL+"/v1/activity", bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(whoHeader, account)
	response, err := c.agent.Do(request)
	if err != nil {
		return err
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("the agent answered " + response.Status)
	}
	return nil
}

func (c *Console) noteOrSay(ctx context.Context, action, result string) {
	if err := c.note(ctx, action, result); err != nil {
		log.Printf("ut-console: %s %s could not be kept in the activity: %v", action, result, err)
	}
}

func randomToken() string {
	random := make([]byte, 32)
	rand.Read(random)
	return hex.EncodeToString(random)
}

// Called with mu held: a failed attempt, and the lock that the fifth one sets.
func (c *Console) failed() (locked bool) {
	c.failures++
	if c.failures < maxFailures {
		return false
	}
	c.failures = 0
	c.lockedUntil = c.now().Add(lockedFor)
	return true
}

// One attempt at a time: each costs 600 000 rounds of SHA-256, and the lock is
// decided before the next one starts.
func (c *Console) signIn(rw http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(rw, r.Body, maxFormBytes)
	password := r.PostFormValue("password")
	c.checking.Lock()
	defer c.checking.Unlock()

	c.mu.Lock()
	locked := c.now().Before(c.lockedUntil)
	c.mu.Unlock()
	if locked {
		c.noteOrSay(r.Context(), "sign-in", "locked")
		http.Error(rw, "Too many wrong passwords. Signing in is blocked for 15 minutes.", http.StatusTooManyRequests)
		return
	}

	stored, err := os.ReadFile(c.passwordFile)
	if errors.Is(err, os.ErrNotExist) || (err == nil && len(bytes.TrimSpace(stored)) == 0) {
		http.Error(rw, "This console has no password yet. On the box, in a terminal: sudo ut-install --reset-console-password", http.StatusServiceUnavailable)
		return
	}
	if err != nil {
		log.Printf("ut-console: the password hash cannot be read: %v", err)
		http.Error(rw, "The console cannot check passwords right now.", http.StatusServiceUnavailable)
		return
	}
	if !passwordMatches(string(stored), password) {
		c.mu.Lock()
		locked = c.failed()
		c.mu.Unlock()
		if locked {
			c.noteOrSay(r.Context(), "sign-in", "locked")
			http.Error(rw, "Too many wrong passwords. Signing in is blocked for 15 minutes.", http.StatusTooManyRequests)
			return
		}
		c.noteOrSay(r.Context(), "sign-in", "refused")
		http.Error(rw, "Wrong password.", http.StatusForbidden)
		return
	}
	if err := c.note(r.Context(), "sign-in", "ok"); err != nil {
		log.Printf("ut-console: a sign-in was refused because the activity could not keep it: %v", err)
		http.Error(rw, "The agent does not answer: nothing can be kept in the activity, so nobody is let in.", http.StatusServiceUnavailable)
		return
	}
	token := randomToken()
	c.mu.Lock()
	c.failures = 0
	now := c.now()
	for old, open := range c.sessions {
		if open.over(now) {
			delete(c.sessions, old)
		}
	}
	c.sessions[token] = session{started: now, seen: now}
	c.mu.Unlock()
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: token, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	rw.WriteHeader(http.StatusNoContent)
}

func (c *Console) signOut(rw http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		c.mu.Lock()
		delete(c.sessions, cookie.Value)
		c.mu.Unlock()
	}
	c.noteOrSay(r.Context(), "sign-out", "ok")
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1, Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	rw.WriteHeader(http.StatusNoContent)
}

// What the page asks is passed on as it came: the agent alone decides what is
// a service or a bound, and notes what it refuses.
func (c *Console) relay(path string, parameters ...string) http.HandlerFunc {
	return func(rw http.ResponseWriter, r *http.Request) {
		query := url.Values{}
		for _, name := range parameters {
			if values, given := r.URL.Query()[name]; given {
				query[name] = values
			}
		}
		target := c.agentURL + path
		if len(query) > 0 {
			target += "?" + query.Encode()
		}
		ctx, cancel := context.WithTimeout(r.Context(), agentTimeout)
		defer cancel()
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if err != nil {
			http.Error(rw, "refused", http.StatusBadRequest)
			return
		}
		request.Header.Set(whoHeader, account)
		response, err := c.agent.Do(request)
		if err != nil {
			log.Printf("ut-console: the agent does not answer: %v", err)
			http.Error(rw, "The agent does not answer.", http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		if kind := response.Header.Get("Content-Type"); strings.HasPrefix(kind, "application/json") || strings.HasPrefix(kind, "text/plain") {
			rw.Header().Set("Content-Type", kind)
		} else {
			rw.Header().Set("Content-Type", "text/plain; charset=utf-8")
		}
		rw.WriteHeader(response.StatusCode)
		io.Copy(rw, io.LimitReader(response.Body, maxAgentAnswer))
	}
}

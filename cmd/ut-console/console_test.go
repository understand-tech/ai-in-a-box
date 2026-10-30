package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const rightPassword = "correct-horse-battery-staple"

// A real hash, at fewer rounds than the console writes: what is under test here
// is the console's door, not PBKDF2.
func cheapHash(t *testing.T, password string) string {
	t.Helper()
	salt := []byte("0123456789abcdef")
	key, err := derive(password, salt, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%s$1000$%s$%s", hashScheme, encoding.EncodeToString(salt), encoding.EncodeToString(key))
}

type fakeAgent struct {
	mu     sync.Mutex
	asked  []*http.Request
	notes  []string
	refuse bool
}

func (f *fakeAgent) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, r)
	switch r.Method + " " + r.URL.Path {
	case "POST /v1/activity":
		if f.refuse {
			http.Error(rw, "the disk is full", http.StatusInternalServerError)
			return
		}
		f.notes = append(f.notes, string(body))
		rw.WriteHeader(http.StatusNoContent)
	case "GET /v1/status":
		rw.Header().Set("Content-Type", "application/json")
		rw.Write([]byte(`{"release":"2026.10.3"}`))
	default:
		rw.Header().Set("Content-Type", "text/plain; charset=utf-8")
		rw.Write([]byte("asked " + r.URL.RequestURI()))
	}
}

func (f *fakeAgent) noted() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.notes...)
}

func (f *fakeAgent) requests() []*http.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*http.Request{}, f.asked...)
}

type consoleUnderTest struct {
	t       *testing.T
	server  *httptest.Server
	console *Console
	client  *http.Client
	agent   *fakeAgent
	now     time.Time
}

func newConsoleUnderTest(t *testing.T) *consoleUnderTest {
	t.Helper()
	agent := &fakeAgent{}
	agentServer := httptest.NewServer(agent)
	t.Cleanup(agentServer.Close)
	passwordFile := filepath.Join(t.TempDir(), "password")
	os.WriteFile(passwordFile, []byte(cheapHash(t, rightPassword)+"\n"), 0o640)

	server := httptest.NewUnstartedServer(nil)
	c := &consoleUnderTest{t: t, server: server, agent: agent, now: time.Date(2026, 10, 29, 14, 0, 0, 0, time.UTC)}
	c.console = newConsole(server.Listener.Addr().String(), agentServer.Client(), agentServer.URL, passwordFile, func() time.Time { return c.now })
	server.Config.Handler = c.console.Handler()
	server.StartTLS()
	t.Cleanup(server.Close)
	c.client = server.Client()
	c.client.Jar, _ = cookiejar.New(nil)
	return c
}

func (c *consoleUnderTest) origin() string { return c.server.URL }

func (c *consoleUnderTest) get(path string) *http.Response {
	c.t.Helper()
	response, err := c.client.Get(c.server.URL + path)
	if err != nil {
		c.t.Fatal(err)
	}
	return response
}

func (c *consoleUnderTest) post(path string, form url.Values, origin string) *http.Response {
	c.t.Helper()
	request, _ := http.NewRequest(http.MethodPost, c.server.URL+path, strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if origin != "" {
		request.Header.Set("Origin", origin)
	}
	response, err := c.client.Do(request)
	if err != nil {
		c.t.Fatal(err)
	}
	response.Body.Close()
	return response
}

func (c *consoleUnderTest) signIn(password string) *http.Response {
	c.t.Helper()
	return c.post("/sign-in", url.Values{"password": {password}}, c.origin())
}

func status(response *http.Response) int {
	response.Body.Close()
	return response.StatusCode
}

func TestNothingIsShownWithoutASession(t *testing.T) {
	c := newConsoleUnderTest(t)
	for _, path := range []string{"/api/status", "/api/logs?service=api&lines=10", "/api/activity?limit=10"} {
		if got := status(c.get(path)); got != http.StatusUnauthorized {
			t.Fatalf("%s without a session answered %d", path, got)
		}
	}
	jar, _ := cookiejar.New(nil)
	address, _ := url.Parse(c.server.URL)
	jar.SetCookies(address, []*http.Cookie{{Name: sessionCookie, Value: strings.Repeat("0", 64), Path: "/"}})
	c.client.Jar = jar
	if got := status(c.get("/api/status")); got != http.StatusUnauthorized {
		t.Fatalf("a made-up session answered %d", got)
	}
	response := c.get("/")
	page, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if !bytes.Contains(page, []byte(`id="sign-in"`)) {
		t.Fatal("the address shows something other than the sign-in page")
	}
	if asked := c.agent.requests(); len(asked) != 0 {
		t.Fatalf("the agent was asked %d times without a session", len(asked))
	}
}

func TestARequestNamingAnotherHostIsRefused(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.signIn(rightPassword)
	for _, host := range []string{"rebound.example.com", "rebound.example.com:" + c.server.URL[strings.LastIndex(c.server.URL, ":")+1:], "127.0.0.1"} {
		request, _ := http.NewRequest(http.MethodGet, c.server.URL+"/api/status", nil)
		request.Host = host
		response, err := c.client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		if got := status(response); got != http.StatusMisdirectedRequest {
			t.Fatalf("the host %q answered %d", host, got)
		}
	}
	for _, r := range c.agent.requests() {
		if r.URL.Path == "/v1/status" {
			t.Fatal("the agent was asked for a request naming another host")
		}
	}
}

func TestAPostFromAnotherOriginIsRefused(t *testing.T) {
	c := newConsoleUnderTest(t)
	for _, origin := range []string{"https://elsewhere.example.com", "http://" + c.server.Listener.Addr().String(), "null", ""} {
		if got := c.post("/sign-in", url.Values{"password": {rightPassword}}, origin).StatusCode; got != http.StatusForbidden {
			t.Fatalf("a sign-in from %q answered %d", origin, got)
		}
	}
	if len(c.agent.noted()) != 0 || len(c.client.Jar.Cookies(&url.URL{Scheme: "https", Host: c.server.Listener.Addr().String()})) != 0 {
		t.Fatal("a sign-in from another origin got somewhere")
	}
}

func TestTheSixthAttemptAfterFiveWrongPasswordsIsBlockedAndNoted(t *testing.T) {
	c := newConsoleUnderTest(t)
	for attempt := 1; attempt <= 4; attempt++ {
		if got := c.signIn("wrong").StatusCode; got != http.StatusForbidden {
			t.Fatalf("wrong password %d answered %d", attempt, got)
		}
	}
	if got := c.signIn("wrong").StatusCode; got != http.StatusTooManyRequests {
		t.Fatalf("the fifth wrong password answered %d", got)
	}
	if got := c.signIn(rightPassword).StatusCode; got != http.StatusTooManyRequests {
		t.Fatalf("the sixth attempt, with the right password, answered %d", got)
	}
	if got := status(c.get("/api/status")); got != http.StatusUnauthorized {
		t.Fatalf("a blocked sign-in opened a session: %d", got)
	}
	notes := c.agent.noted()
	if len(notes) != 6 || !strings.Contains(notes[3], `"result":"refused"`) || !strings.Contains(notes[4], `"result":"locked"`) || !strings.Contains(notes[5], `"result":"locked"`) {
		t.Fatalf("the activity was told %q", notes)
	}
	c.now = c.now.Add(lockedFor + time.Second)
	if got := c.signIn(rightPassword).StatusCode; got != http.StatusNoContent {
		t.Fatalf("the right password after the block answered %d", got)
	}
}

func TestTheSessionCookieIsHostOnlySecureHttpOnlyAndStrict(t *testing.T) {
	c := newConsoleUnderTest(t)
	response := c.signIn(rightPassword)
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("the right password answered %d", response.StatusCode)
	}
	cookies := response.Cookies()
	if len(cookies) != 1 {
		t.Fatalf("set %d cookies", len(cookies))
	}
	cookie := cookies[0]
	if cookie.Name != "__Host-ut-console" || !cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" || cookie.Domain != "" {
		t.Fatalf("the session cookie is %s", response.Header.Get("Set-Cookie"))
	}
	if len(cookie.Value) != 64 {
		t.Fatalf("the session is %d characters, not 32 bytes in hex", len(cookie.Value))
	}
}

func TestEveryAnswerCarriesThePolicy(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.signIn(rightPassword)
	request, _ := http.NewRequest(http.MethodGet, c.server.URL+"/", nil)
	request.Host = "rebound.example.com"
	misdirected, _ := c.client.Do(request)
	for _, response := range []*http.Response{c.get("/"), c.get("/page/app.js"), c.get("/api/status"), c.get("/api/logs?service=api&lines=10"), misdirected} {
		response.Body.Close()
		headers := response.Header
		if headers.Get("Content-Security-Policy") != "default-src 'self'; frame-ancestors 'none'" ||
			headers.Get("Referrer-Policy") != "no-referrer" || headers.Get("Cache-Control") != "no-store" ||
			headers.Get("X-Content-Type-Options") != "nosniff" {
			t.Fatalf("%s answered with %v", response.Request.URL.Path, headers)
		}
	}
}

func TestASessionEndsAfterFifteenIdleMinutesOrEightHours(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.signIn(rightPassword)
	for range 40 {
		c.now = c.now.Add(14 * time.Minute)
		if got := status(c.get("/api/status")); got != http.StatusOK && c.now.Before(time.Date(2026, 10, 29, 22, 0, 0, 0, time.UTC)) {
			t.Fatalf("a session in use ended at %v: %d", c.now, got)
		}
	}
	if got := status(c.get("/api/status")); got != http.StatusUnauthorized {
		t.Fatalf("a session open for more than eight hours answered %d", got)
	}
	c.signIn(rightPassword)
	c.now = c.now.Add(15*time.Minute + time.Second)
	if got := status(c.get("/api/status")); got != http.StatusUnauthorized {
		t.Fatalf("a session idle for more than fifteen minutes answered %d", got)
	}
}

func TestSigningOutEndsTheSessionAndIsNoted(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.signIn(rightPassword)
	if got := c.post("/sign-out", nil, c.origin()).StatusCode; got != http.StatusNoContent {
		t.Fatalf("signing out answered %d", got)
	}
	if got := status(c.get("/api/status")); got != http.StatusUnauthorized {
		t.Fatalf("after signing out the console answered %d", got)
	}
	notes := c.agent.noted()
	if len(notes) != 2 || notes[1] != `{"action":"sign-out","result":"ok","who":"admin"}` {
		t.Fatalf("the activity was told %q", notes)
	}
}

func TestNoPasswordReachesTheAgent(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.signIn("a-wrong-one-to-remember")
	c.signIn(rightPassword)
	c.get("/api/status").Body.Close()
	for _, note := range c.agent.noted() {
		if strings.Contains(note, "a-wrong-one-to-remember") || strings.Contains(note, rightPassword) {
			t.Fatalf("the agent was sent %s", note)
		}
	}
	for _, r := range c.agent.requests() {
		if strings.Contains(r.URL.String(), rightPassword) {
			t.Fatalf("the agent was asked %s", r.URL)
		}
	}
}

func TestASignInTheActivityCannotKeepLetsNobodyIn(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.agent.refuse = true
	response := c.signIn(rightPassword)
	if response.StatusCode != http.StatusServiceUnavailable || len(response.Cookies()) != 0 {
		t.Fatalf("a sign-in nobody could note answered %d with %v", response.StatusCode, response.Cookies())
	}
}

func TestTheAgentIsAskedAsTheAccountWithWhatThePageSent(t *testing.T) {
	c := newConsoleUnderTest(t)
	c.signIn(rightPassword)
	response := c.get("/api/logs?service=api%3B+reboot&lines=10&follow=1")
	answer, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(answer) != "asked /v1/logs?lines=10&service=api%3B+reboot" {
		t.Fatalf("the agent was asked %q", answer)
	}
	requests := c.agent.requests()
	if who := requests[len(requests)-1].Header.Get(whoHeader); who != "admin" {
		t.Fatalf("the agent was asked by %q", who)
	}
	response = c.get("/api/status")
	var status map[string]string
	json.NewDecoder(response.Body).Decode(&status)
	response.Body.Close()
	if status["release"] != "2026.10.3" || response.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("the status came back as %v, %q", status, response.Header.Get("Content-Type"))
	}
}

func TestAConsoleWithNoPasswordYetSaysHowToGetOne(t *testing.T) {
	c := newConsoleUnderTest(t)
	os.Remove(c.console.passwordFile)
	request, _ := http.NewRequest(http.MethodPost, c.server.URL+"/sign-in", strings.NewReader("password=anything"))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", c.origin())
	response, _ := c.client.Do(request)
	said, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable || !strings.Contains(string(said), "ut-install --reset-console-password") {
		t.Fatalf("answered %d: %s", response.StatusCode, said)
	}
	if c.console.failures != 0 {
		t.Fatal("a box with no password counted a failure")
	}
}

package main

import (
	"context"
	"encoding/json"
	"errors"
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

const (
	testCode    = "abcdefghjkmnpqrstuvw"
	testSession = "0123456789abcdef"
)

type fakeInstall struct {
	mu      sync.Mutex
	calls   [][]string
	license string
	lines   []string
	fail    bool
}

func (f *fakeInstall) run(_ context.Context, args []string, line func(string)) error {
	f.mu.Lock()
	f.calls = append(f.calls, args)
	for i, arg := range args {
		if arg == "--license-file" {
			content, _ := os.ReadFile(args[i+1])
			f.license = string(content)
		}
	}
	lines, fail := f.lines, f.fail
	f.mu.Unlock()
	for _, l := range lines {
		line(l)
	}
	if fail {
		return errors.New("ut-install exited with 1")
	}
	return nil
}

func (f *fakeInstall) called() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

type box struct {
	t      *testing.T
	server *httptest.Server
	wizard *Wizard
	client *http.Client
	fake   *fakeInstall
}

func newBox(t *testing.T, fake *fakeInstall) *box {
	t.Helper()
	server := httptest.NewUnstartedServer(nil)
	wizard := newWizard(fake.run, testCode, testSession, server.Listener.Addr().String())
	server.Config.Handler = wizard.Handler()
	server.Start()
	t.Cleanup(server.Close)
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return &box{t, server, wizard, client, fake}
}

func (b *box) get(path string) *http.Response {
	b.t.Helper()
	response, err := b.client.Get(b.server.URL + path)
	if err != nil {
		b.t.Fatal(err)
	}
	return response
}

func (b *box) post(path string, form url.Values, origin string) *http.Response {
	b.t.Helper()
	request, _ := http.NewRequest(http.MethodPost, b.server.URL+path, strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", origin)
	response, err := b.client.Do(request)
	if err != nil {
		b.t.Fatal(err)
	}
	return response
}

func (b *box) enter(code string) int {
	b.t.Helper()
	return b.post("/enter", url.Values{"code": {code}}, b.server.URL).StatusCode
}

func (b *box) signIn() {
	b.t.Helper()
	if status := b.enter(testCode); status != http.StatusNoContent {
		b.t.Fatalf("the right code answered %d", status)
	}
}

func (b *box) answer(form url.Values) *http.Response {
	return b.post("/install", form, b.server.URL)
}

func (b *box) waitForTheEnd() Progress {
	b.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var progress Progress
		response := b.get("/progress")
		json.NewDecoder(response.Body).Decode(&progress)
		response.Body.Close()
		if progress.Finished {
			return progress
		}
		time.Sleep(10 * time.Millisecond)
	}
	b.t.Fatal("the install never finished")
	return Progress{}
}

func goodAnswers() url.Values {
	return url.Values{"domain": {"Box.Example.com"}, "license": {"UT1.licence-key"}, "reporting": {"no"}}
}

func TestOnlyTheCodeOpensTheWizard(t *testing.T) {
	b := newBox(t, &fakeInstall{})
	if status := b.get("/").StatusCode; status != http.StatusForbidden {
		t.Fatalf("no code answered %d", status)
	}
	if status := b.enter("wrong"); status != http.StatusForbidden {
		t.Fatalf("a wrong code answered %d", status)
	}
	b.signIn()
	if status := b.get("/").StatusCode; status != http.StatusOK {
		t.Fatalf("the signed-in browser got %d", status)
	}
	other := newBox(t, &fakeInstall{})
	other.server = b.server
	if status := other.enter(testCode); status != http.StatusForbidden {
		t.Fatalf("the code opened a second browser: %d", status)
	}
}

func TestShowingTheAddressSpendsNothing(t *testing.T) {
	b := newBox(t, &fakeInstall{})
	preview := newBox(t, &fakeInstall{})
	preview.server = b.server
	for range maxFailures + 1 {
		if status := preview.get("/?code=" + testCode).StatusCode; status != http.StatusOK {
			t.Fatalf("showing the address answered %d", status)
		}
	}
	b.signIn()
	if status := b.get("/").StatusCode; status != http.StatusOK {
		t.Fatalf("the browser that clicked got %d", status)
	}
}

func TestTheAddressOpenedAgainInTheSameBrowserShowsThePage(t *testing.T) {
	b := newBox(t, &fakeInstall{})
	b.signIn()
	if status := b.get("/?code=" + testCode).StatusCode; status != http.StatusSeeOther {
		t.Fatalf("the same browser opening the address again got %d", status)
	}
	if status := b.get("/").StatusCode; status != http.StatusOK {
		t.Fatalf("then the page answered %d", status)
	}
	if b.wizard.failures != 0 {
		t.Fatalf("counted %d failures", b.wizard.failures)
	}
}

func TestFiveWrongCodesStopTheWizard(t *testing.T) {
	b := newBox(t, &fakeInstall{})
	for range maxFailures {
		b.enter("wrong")
	}
	select {
	case reason := <-b.wizard.Stopped():
		if !strings.Contains(reason, "wrong codes") {
			t.Fatalf("stopped for %q", reason)
		}
	case <-time.After(time.Second):
		t.Fatal("still answering after five wrong codes")
	}
}

func TestARequestNamingAnotherHostIsRefused(t *testing.T) {
	b := newBox(t, &fakeInstall{})
	request, _ := http.NewRequest(http.MethodGet, b.server.URL+"/", nil)
	request.Host = "rebound.example.com"
	response, err := b.client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusMisdirectedRequest {
		t.Fatalf("another host name answered %d", response.StatusCode)
	}
}

func TestAPostFromAnotherOriginIsRefused(t *testing.T) {
	fake := &fakeInstall{}
	b := newBox(t, fake)
	b.signIn()
	if status := b.post("/install", goodAnswers(), "http://elsewhere.example.com").StatusCode; status != http.StatusForbidden {
		t.Fatalf("a post from another origin answered %d", status)
	}
	if len(fake.called()) != 0 {
		t.Fatal("ut-install ran for another origin")
	}
}

func TestNothingRunsWithoutTheSession(t *testing.T) {
	fake := &fakeInstall{}
	b := newBox(t, fake)
	if status := b.answer(goodAnswers()).StatusCode; status != http.StatusForbidden {
		t.Fatalf("an install without the session answered %d", status)
	}
	if len(fake.called()) != 0 {
		t.Fatal("ut-install ran without the session")
	}
}

func TestTheAnswersReachUtInstallAndTheKeyIsNeverAnArgument(t *testing.T) {
	fake := &fakeInstall{}
	b := newBox(t, fake)
	b.signIn()
	if status := b.answer(goodAnswers()).StatusCode; status != http.StatusAccepted {
		t.Fatalf("the answers got %d", status)
	}
	b.waitForTheEnd()
	args := fake.called()[0]
	if strings.Contains(strings.Join(args, " "), "UT1.licence-key") {
		t.Fatalf("the key is on the command line: %v", args)
	}
	if args[0] != "--domain" || args[1] != "box.example.com" || args[2] != "--license-file" || args[4] != "--reporting" || args[5] != "no" {
		t.Fatalf("ut-install was called with %v", args)
	}
	if fake.license != "UT1.licence-key\n" {
		t.Fatalf("the license file held %q", fake.license)
	}
	if _, err := os.Stat(args[3]); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the license file is still there: %v", err)
	}
}

func TestAnswersThatAreNotAnswersRunNothing(t *testing.T) {
	fake := &fakeInstall{}
	b := newBox(t, fake)
	b.signIn()
	for _, form := range []url.Values{
		{"domain": {"not a host"}, "license": {"k"}, "reporting": {"no"}},
		{"domain": {"box.example.com"}, "license": {""}, "reporting": {"no"}},
		{"domain": {"box.example.com"}, "license": {"k\n--reporting yes"}, "reporting": {"no"}},
		{"domain": {"box.example.com"}, "license": {"k"}, "reporting": {"maybe"}},
	} {
		if status := b.answer(form).StatusCode; status != http.StatusUnprocessableEntity {
			t.Fatalf("%v answered %d", form, status)
		}
	}
	if len(fake.called()) != 0 {
		t.Fatal("ut-install ran on answers it should have refused")
	}
}

func TestTheProgressIsWhatUtInstallSays(t *testing.T) {
	b := newBox(t, &fakeInstall{lines: []string{"==> Downloading images", "     7/13  ghcr.io/x/api:1  (2 min)"}})
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	if progress.Step != "Downloading images" || progress.Landed != 7 || progress.Total != 13 || progress.Domain != "box.example.com" {
		t.Fatalf("progress read as %+v", progress)
	}
}

func TestAFailedInstallSaysWhyAndCanRunAgain(t *testing.T) {
	fake := &fakeInstall{lines: []string{"==> Downloading images", "[fail] Image pull failed. Check the token and the network."}, fail: true}
	b := newBox(t, fake)
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	if progress.Succeeded || progress.Failure != "Image pull failed. Check the token and the network." {
		t.Fatalf("a failure read as %+v", progress)
	}
	if status := b.answer(goodAnswers()).StatusCode; status != http.StatusAccepted {
		t.Fatalf("running again answered %d", status)
	}
	b.waitForTheEnd()
	if len(fake.called()) != 2 {
		t.Fatalf("ut-install ran %d times", len(fake.called()))
	}
}

func TestTheSecretsAreShownOnceThenTheWizardStops(t *testing.T) {
	settings := filepath.Join(t.TempDir(), "local.env")
	os.WriteFile(settings, []byte("ADMIN_SETUP_PASSWORD=\"first-door\"\nBACKUP_FILES_PASSWORD=\"keep-it-safe\"\n"), 0o600)
	b := newBox(t, &fakeInstall{lines: []string{"[ ok ] No terminal here, so nothing was printed. The secrets are in " + settings}})
	b.signIn()
	if status := b.post("/secrets", nil, b.server.URL).StatusCode; status != http.StatusGone {
		t.Fatalf("secrets before the install answered %d", status)
	}
	b.answer(goodAnswers())
	b.waitForTheEnd()

	response := b.post("/secrets", nil, b.server.URL)
	var secrets Secrets
	json.NewDecoder(response.Body).Decode(&secrets)
	if secrets.AdminPassword != "first-door" || secrets.BackupPassword != "keep-it-safe" {
		t.Fatalf("secrets read as %+v", secrets)
	}
	if response.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("the secrets may be cached")
	}
	if status := b.post("/secrets", nil, b.server.URL).StatusCode; status != http.StatusGone {
		t.Fatalf("the secrets were served twice: %d", status)
	}
	select {
	case <-b.wizard.Stopped():
	case <-time.After(time.Second):
		t.Fatal("the wizard did not stop once the secrets were shown")
	}
}

func TestTheWarningsAndTheStepsReachThePage(t *testing.T) {
	b := newBox(t, &fakeInstall{lines: []string{
		"==> Writing the configuration",
		"[warn] OA_KEY has no value. The platform API builds an OpenAI client as it",
		"==> Starting services",
		"[fail] Install stopped at line 226 (exit 1).",
	}, fail: true})
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	if strings.Join(progress.Steps, "|") != "Writing the configuration|Starting services" {
		t.Fatalf("steps read as %q", progress.Steps)
	}
	if len(progress.Warnings) != 1 || !strings.HasPrefix(progress.Warnings[0], "OA_KEY has no value") {
		t.Fatalf("warnings read as %q", progress.Warnings)
	}
}

func TestTheBoxIsCheckedOnceWithCheck(t *testing.T) {
	fake := &fakeInstall{lines: []string{"[ ok ] Docker 29.2.1", "[fail] Disk: 91 GB free, 250 GB needed"}, fail: true}
	b := newBox(t, fake)
	if status := b.get("/check").StatusCode; status != http.StatusForbidden {
		t.Fatalf("the check without the session answered %d", status)
	}
	b.signIn()
	var readiness Readiness
	for range 2 {
		response := b.get("/check")
		json.NewDecoder(response.Body).Decode(&readiness)
		response.Body.Close()
	}
	if readiness.Ready || len(readiness.Lines) != 2 {
		t.Fatalf("readiness read as %+v", readiness)
	}
	calls := fake.called()
	if len(calls) != 1 || strings.Join(calls[0], " ") != "--check" {
		t.Fatalf("ut-install was called %v", calls)
	}
}

func TestTheWizardListensOnThisMachineOnly(t *testing.T) {
	listener, err := listen()
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if address := listener.Addr().String(); !strings.HasPrefix(address, "127.0.0.1:") {
		t.Fatalf("listening on %s", address)
	}
}

func TestAnInstallerThatCannotStartIsAFailure(t *testing.T) {
	var said []string
	err := runInstaller(filepath.Join(t.TempDir(), "absent"))(context.Background(), nil, func(l string) { said = append(said, l) })
	if err == nil {
		t.Fatal("a missing installer was a success")
	}
}

func TestTheRealInstallerIsReadLineByLine(t *testing.T) {
	script := filepath.Join(t.TempDir(), "ut-install")
	os.WriteFile(script, []byte("#!/bin/sh\necho '==> Downloading images'\necho '[fail] stopped' >&2\nexit 3\n"), 0o755)
	var said []string
	err := runInstaller(script)(context.Background(), nil, func(l string) { said = append(said, l) })
	if err == nil || !strings.Contains(err.Error(), "exited with 3") {
		t.Fatalf("exit read as %v", err)
	}
	if strings.Join(said, "|") != "==> Downloading images|[fail] stopped" {
		t.Fatalf("lines read as %q", said)
	}
}

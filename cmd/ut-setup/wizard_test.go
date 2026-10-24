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
	events  []Event
	fail    bool
}

func said(kind, text string) Event { return Event{V: eventsVersion, Event: kind, Text: text} }

func (f *fakeInstall) run(_ context.Context, args []string, line func(string), happened func(Event)) error {
	f.mu.Lock()
	f.calls = append(f.calls, args)
	for i, arg := range args {
		if arg == "--license-file" {
			content, _ := os.ReadFile(args[i+1])
			f.license = string(content)
		}
	}
	lines, events, fail := f.lines, f.events, f.fail
	f.mu.Unlock()
	for _, l := range lines {
		line(l)
	}
	for _, event := range events {
		happened(event)
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
	return newBoxFrom(t, fake, Folder{})
}

func newBoxFrom(t *testing.T, fake *fakeInstall, folder Folder) *box {
	t.Helper()
	server := httptest.NewUnstartedServer(nil)
	wizard := newWizard(fake.run, folder, testCode, testSession, server.Listener.Addr().String())
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
	total := 13
	b := newBox(t, &fakeInstall{events: []Event{said("step", "Downloading images"), {V: eventsVersion, Event: "image", Landed: 7, Total: &total, Name: "ghcr.io/x/api:1"}}})
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	if progress.Step != "Downloading images" || progress.Landed != 7 || progress.Total != 13 || progress.Domain != "box.example.com" {
		t.Fatalf("progress read as %+v", progress)
	}
}

func TestAFailedInstallSaysWhyAndCanRunAgain(t *testing.T) {
	fake := &fakeInstall{events: []Event{said("step", "Downloading images"), said("fail", "Image pull failed. Check the token and the network.")}, fail: true}
	b := newBox(t, fake)
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	if progress.Succeeded || len(progress.Messages) != 1 || progress.Messages[0] != (Message{"fail", "Image pull failed. Check the token and the network."}) {
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
	b := newBox(t, &fakeInstall{events: []Event{{V: eventsVersion, Event: "secrets", File: settings}}})
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
	b := newBox(t, &fakeInstall{events: []Event{
		said("step", "Writing the configuration"),
		said("warn", "OA_KEY has no value. The platform API builds an OpenAI client as it"),
		said("step", "Starting services"),
		said("fail", "Install stopped at line 226 (exit 1)."),
	}, fail: true})
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	if strings.Join(progress.Steps, "|") != "Writing the configuration|Starting services" {
		t.Fatalf("steps read as %q", progress.Steps)
	}
	if len(progress.Messages) != 2 || progress.Messages[0].Kind != "warn" || !strings.HasPrefix(progress.Messages[0].Text, "OA_KEY has no value") {
		t.Fatalf("messages read as %q", progress.Messages)
	}
}

func (b *box) readiness() Readiness {
	b.t.Helper()
	var readiness Readiness
	response := b.get("/check")
	json.NewDecoder(response.Body).Decode(&readiness)
	response.Body.Close()
	return readiness
}

func (f *fakeInstall) nowSays(events ...Event) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail, f.events = false, events
}

func TestABoxFoundNotReadyIsCheckedAgainAndOneFoundReadyIsNot(t *testing.T) {
	fake := &fakeInstall{events: []Event{said("ok", "Docker 29.2.1"), said("fail", "Disk: 91 GB free, 250 GB needed")}, fail: true}
	b := newBox(t, fake)
	if status := b.get("/check").StatusCode; status != http.StatusForbidden {
		t.Fatalf("the check without the session answered %d", status)
	}
	b.signIn()
	for range 2 {
		if readiness := b.readiness(); readiness.Ready || len(readiness.Messages) != 2 || readiness.Messages[1].Kind != "fail" {
			t.Fatalf("readiness read as %+v", readiness)
		}
	}
	fake.nowSays(said("ok", "Disk: 300 GB free"))
	for range 2 {
		if readiness := b.readiness(); !readiness.Ready {
			t.Fatalf("a box fixed in between still read as %+v", readiness)
		}
	}
	calls := fake.called()
	if len(calls) != 3 {
		t.Fatalf("ut-install --check ran %d times, not 3: %v", len(calls), calls)
	}
	for _, call := range calls {
		if strings.Join(call, " ") != "--check" {
			t.Fatalf("ut-install was called %v", calls)
		}
	}
}

func TestModelsThatCouldNotBeListedAreAskedForAgain(t *testing.T) {
	fake := &fakeInstall{fail: true}
	b := newBox(t, fake)
	b.signIn()
	b.get("/models").Body.Close()
	fake.nowSays(Event{V: eventsVersion, Event: "model", ID: "qwen3.8-27b-nvfp4"})
	var models []Model
	for range 2 {
		response := b.get("/models")
		json.NewDecoder(response.Body).Decode(&models)
		response.Body.Close()
	}
	if len(models) != 1 || len(fake.called()) != 2 {
		t.Fatalf("offered %+v after %d calls", models, len(fake.called()))
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
	err := runInstaller(filepath.Join(t.TempDir(), "absent"))(context.Background(), nil, func(l string) { said = append(said, l) }, func(Event) {})
	if err == nil {
		t.Fatal("a missing installer was a success")
	}
}

func TestTheRealInstallerIsReadLineByLineAndEventByEvent(t *testing.T) {
	script := filepath.Join(t.TempDir(), "ut-install")
	os.WriteFile(script, []byte(`#!/bin/sh
[ "$1" = --events ] || exit 9
echo '==> Downloading images'
printf '{"v":1,"event":"step","text":"Downloading images"}\n' >> "$2"
echo '[fail] stopped' >&2
printf 'not an event\n{"v":2,"event":"fail","text":"a version this page does not read"}\n' >> "$2"
printf '{"v":1,"event":"fail","text":"stopped"}\n' >> "$2"
exit 3
`), 0o755)
	var lines []string
	var events []Event
	err := runInstaller(script)(context.Background(), []string{"--check"}, func(l string) { lines = append(lines, l) }, func(e Event) { events = append(events, e) })
	if err == nil || !strings.Contains(err.Error(), "exited with 3") {
		t.Fatalf("exit read as %v", err)
	}
	if strings.Join(lines, "|") != "==> Downloading images|[fail] stopped" {
		t.Fatalf("lines read as %q", lines)
	}
	if len(events) != 2 || events[0].Text != "Downloading images" || events[1] != said("fail", "stopped") {
		t.Fatalf("events read as %+v", events)
	}
}

func TestALineTooLongToReadDoesNotHoldTheInstallerUp(t *testing.T) {
	script := filepath.Join(t.TempDir(), "ut-install")
	os.WriteFile(script, []byte("#!/bin/sh\nhead -c 2097152 /dev/zero | tr '\\0' x\necho\necho after\n"), 0o755)
	finished := make(chan error, 1)
	go func() {
		finished <- runInstaller(script)(context.Background(), nil, func(string) {}, func(Event) {})
	}()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatalf("the installer ended with %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the installer is still blocked on a line nobody read")
	}
}

func TestTheFolderReachesEveryCallOfUtInstallAndTheKeyNone(t *testing.T) {
	fake := &fakeInstall{events: []Event{said("ok", "System ready")}}
	b := newBoxFrom(t, fake, Folder{Images: "/media/box", License: "/media/box/box.lic"})
	b.signIn()
	if readiness := b.readiness(); !readiness.FromFolder || !readiness.LicenseFromFolder {
		t.Fatalf("readiness read as %+v", readiness)
	}
	b.get("/models").Body.Close()
	if status := b.answer(url.Values{"domain": {"box.example.com"}, "reporting": {"yes"}}).StatusCode; status != http.StatusAccepted {
		t.Fatalf("the answers without a key got %d", status)
	}
	b.waitForTheEnd()
	calls := fake.called()
	if len(calls) != 3 {
		t.Fatalf("ut-install ran %d times: %v", len(calls), calls)
	}
	for _, call := range calls {
		if strings.Join(call[:4], " ") != "--images-from /media/box --machine-file /media/box/box.lic" {
			t.Fatalf("a call without the folder: %v", call)
		}
	}
	install := strings.Join(calls[2], " ")
	if strings.Contains(install, "--license-file") || !strings.HasSuffix(install, "--domain box.example.com --reporting no") {
		t.Fatalf("installed with %q", install)
	}
}

func TestAMessageCarriedOverSeveralLinesReachesThePageWhole(t *testing.T) {
	b := newBox(t, &fakeInstall{events: []Event{
		said("ok", "Docker 29.2.1"),
		said("fail", "Docker cannot create a network — its address pools are full."),
		said("more", "  The stack needs four. Reclaim the ones nothing uses:"),
		said("more", "    docker network prune"),
		said("more", ""),
		said("fail", "Blocking problems found. Nothing was changed."),
	}, fail: true})
	b.signIn()
	b.answer(goodAnswers())
	progress := b.waitForTheEnd()
	whole := "Docker cannot create a network — its address pools are full.\n  The stack needs four. Reclaim the ones nothing uses:\n    docker network prune"
	if len(progress.Messages) != 3 || progress.Messages[1] != (Message{"fail", whole}) || progress.Messages[2].Text != "Blocking problems found. Nothing was changed." {
		t.Fatalf("messages read as %q", progress.Messages)
	}
}

func TestTheModelsOfferedAreThoseUtInstallLists(t *testing.T) {
	fake := &fakeInstall{events: []Event{
		{V: eventsVersion, Event: "model", ID: "nemotron-3.5-bolt-74b", Served: "vLLM on gb10", Size: "25.1 GB", License: "OpenMDW-1.1", RunsItsOwnCode: true},
		{V: eventsVersion, Event: "model", ID: "qwen3.8-27b-nvfp4", Served: "NIM on gb10", Size: "26.4 GB", License: "apache-2.0"},
		said("warn", "Not proven on gb10: other-model"),
	}}
	b := newBox(t, fake)
	b.signIn()
	var models []Model
	for range 2 {
		response := b.get("/models")
		json.NewDecoder(response.Body).Decode(&models)
		response.Body.Close()
	}
	if len(models) != 2 || models[0] != (Model{"nemotron-3.5-bolt-74b", "vLLM on gb10", "25.1 GB", "OpenMDW-1.1", true}) || models[1].License != "apache-2.0" || models[1].RunsItsOwnCode {
		t.Fatalf("offered %+v", models)
	}
	calls := fake.called()
	if len(calls) != 1 || strings.Join(calls[0], " ") != "--list-models" {
		t.Fatalf("ut-install was called %v", calls)
	}
}

func TestAModelChosenReachesUtInstall(t *testing.T) {
	fake := &fakeInstall{events: []Event{{V: eventsVersion, Event: "model", ID: "qwen3.8-27b-nvfp4"}}}
	b := newBox(t, fake)
	b.signIn()
	answers := goodAnswers()
	answers.Set("model", "qwen3.8-27b-nvfp4")
	if status := b.answer(answers).StatusCode; status != http.StatusAccepted {
		t.Fatalf("the answers got %d", status)
	}
	b.waitForTheEnd()
	calls := fake.called()
	if got := strings.Join(calls[len(calls)-1], " "); !strings.HasSuffix(got, "--reporting no --model qwen3.8-27b-nvfp4") {
		t.Fatalf("ut-install was called with %q", got)
	}
}

func TestAModelThisBoxDoesNotListInstallsNothing(t *testing.T) {
	fake := &fakeInstall{events: []Event{{V: eventsVersion, Event: "model", ID: "qwen3.8-27b-nvfp4"}, said("warn", "Not proven on gb10: other-model")}}
	b := newBox(t, fake)
	b.signIn()
	for _, model := range []string{"other-model", "--engine", "Qwen; reboot"} {
		answers := goodAnswers()
		answers.Set("model", model)
		if status := b.answer(answers).StatusCode; status != http.StatusUnprocessableEntity {
			t.Fatalf("the model %q answered %d", model, status)
		}
	}
	for _, call := range fake.called() {
		if strings.Join(call, " ") != "--list-models" {
			t.Fatalf("ut-install ran %v", call)
		}
	}
}

func installedHere() Event {
	return Event{V: eventsVersion, Event: "installed", Role: "appliance", Address: "box.example.com", Model: "qwen3.8-27b-nvfp4",
		Reporting: true, Licensed: true, Installed: "2026.10.0-rc16", Release: "2026.10.0-rc17"}
}

func TestAnInstalledBoxIsUpdatedAsItIsWithNoAnswerPassed(t *testing.T) {
	fake := &fakeInstall{events: []Event{installedHere(), said("ok", "System ready")}}
	b := newBox(t, fake)
	b.signIn()
	installed := b.readiness().Installed
	if installed == nil || installed.Address != "box.example.com" || installed.Installed != "2026.10.0-rc16" || installed.Release != "2026.10.0-rc17" || !installed.Licensed {
		t.Fatalf("the installation read as %+v", installed)
	}
	if status := b.post("/update", url.Values{}, b.server.URL).StatusCode; status != http.StatusAccepted {
		t.Fatalf("the update got %d", status)
	}
	progress := b.waitForTheEnd()
	if !progress.Update || progress.Domain != "box.example.com" {
		t.Fatalf("the update reported %+v", progress)
	}
	calls := fake.called()
	if last := calls[len(calls)-1]; len(last) != 0 {
		t.Fatalf("the update passed %v, which would replace what the box runs", last)
	}
}

func TestAnInstalledBoxRefusesAnswersThatWouldReplaceItsSettings(t *testing.T) {
	fake := &fakeInstall{events: []Event{installedHere(), said("ok", "System ready")}}
	b := newBox(t, fake)
	b.signIn()
	b.readiness()
	response := b.answer(url.Values{"domain": {"understand.local"}, "license": {"UT1-key"}, "reporting": {"no"}})
	response.Body.Close()
	if response.StatusCode != http.StatusConflict || len(fake.called()) != 1 {
		t.Fatalf("answers on an installed box got %d after %d calls", response.StatusCode, len(fake.called()))
	}
}

func TestABoxWithNothingInstalledHasNothingToUpdate(t *testing.T) {
	fake := &fakeInstall{events: []Event{said("ok", "System ready")}}
	b := newBox(t, fake)
	b.signIn()
	if b.readiness().Installed != nil {
		t.Fatal("a fresh box read as installed")
	}
	response := b.post("/update", url.Values{}, b.server.URL)
	response.Body.Close()
	if response.StatusCode != http.StatusConflict || len(fake.called()) != 1 {
		t.Fatalf("an update of nothing got %d after %d calls", response.StatusCode, len(fake.called()))
	}
}

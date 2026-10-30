package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

var testNow = time.Date(2026, 10, 29, 14, 0, 0, 0, time.UTC)

type fakeBox struct {
	mu      sync.Mutex
	calls   []string
	answers map[string]string
}

func (f *fakeBox) run(_ string, name string, args ...string) (string, error) {
	call := strings.Join(append([]string{name}, args...), " ")
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call)
	if answer, ok := f.answers[call]; ok {
		return answer, nil
	}
	return "", errors.New("exited with 1")
}

func (f *fakeBox) called() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.calls...)
}

func servicesAnswer() map[string]string {
	return map[string]string{"docker compose config --services": "caddy\napi\nfiles-backup\n"}
}

type agentUnderTest struct {
	t        *testing.T
	server   *httptest.Server
	fake     *fakeBox
	activity *Activity
}

func newAgentUnderTest(t *testing.T, answers map[string]string) *agentUnderTest {
	t.Helper()
	install := t.TempDir()
	os.WriteFile(filepath.Join(install, ".env"), []byte("UT_DOMAIN=\"box.example.test\"\nUT_RELEASE_VERSION=\"2026.10.3+abc1234\"\nUT_MODEL=\"qwen3.8-27b-nvfp4\"\n"), 0o600)
	fake := &fakeBox{answers: answers}
	activity := newActivity(filepath.Join(t.TempDir(), "activity", "activity.jsonl"))
	agent := newAgent(Box{Install: install}, fake.run, activity, func() time.Time { return testNow })
	agent.space = func(path string) (uint64, int64, int64, bool) { return 1, 1000, 400, true }
	server := httptest.NewServer(agent)
	t.Cleanup(server.Close)
	return &agentUnderTest{t, server, fake, activity}
}

func (a *agentUnderTest) ask(method, path, body string) *http.Response {
	a.t.Helper()
	request, _ := http.NewRequest(method, a.server.URL+path, strings.NewReader(body))
	request.Header.Set(whoHeader, "admin")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		a.t.Fatal(err)
	}
	return response
}

func (a *agentUnderTest) lines() []Line {
	a.t.Helper()
	lines, err := a.activity.last(maxActivityLimit)
	if err != nil {
		a.t.Fatal(err)
	}
	return lines
}

func (a *agentUnderTest) ranAnyOf(prefixes ...string) []string {
	var ran []string
	for _, call := range a.fake.called() {
		for _, prefix := range prefixes {
			if strings.HasPrefix(call, prefix) {
				ran = append(ran, call)
			}
		}
	}
	return ran
}

func TestARouteOrMethodOutsideTheListIsRefusedRunsNothingAndIsNoted(t *testing.T) {
	a := newAgentUnderTest(t, servicesAnswer())
	asked := []struct{ method, path string }{
		{"POST", "/v1/restart"},
		{"POST", "/v1/status"},
		{"DELETE", "/v1/activity"},
		{"HEAD", "/v1/status"},
		{"GET", "/v1//status"},
		{"GET", "/v2/status"},
	}
	for _, request := range asked {
		response := a.ask(request.method, request.path, "")
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatalf("%s %s answered %d", request.method, request.path, response.StatusCode)
		}
	}
	if calls := a.fake.called(); len(calls) != 0 {
		t.Fatalf("a refused request ran %q", calls)
	}
	lines := a.lines()
	if len(lines) != len(asked) {
		t.Fatalf("the activity kept %d lines for %d refusals: %+v", len(lines), len(asked), lines)
	}
	if lines[0] != (Line{At: "2026-10-29T14:00:00Z", Who: "admin", Action: "refused", Result: "refused", Detail: "GET /v2/status"}) {
		t.Fatalf("the last refusal reads %+v", lines[0])
	}
}

func TestAServiceTheBoxDoesNotRunHasNoLogsRead(t *testing.T) {
	a := newAgentUnderTest(t, servicesAnswer())
	for _, service := range []string{"mongodb", "api; reboot", "../../etc/shadow", "--help", "", "API"} {
		response := a.ask("GET", "/v1/logs?"+url.Values{"service": {service}, "lines": {"10"}}.Encode(), "")
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatalf("logs of %q answered %d", service, response.StatusCode)
		}
	}
	if ran := a.ranAnyOf("docker compose logs"); len(ran) != 0 {
		t.Fatalf("logs were read for a service outside the list: %q", ran)
	}
	if lines := a.lines(); len(lines) != 6 || lines[0].Action != "refused" || lines[0].Detail != "GET /v1/logs: a service this box does not run" {
		t.Fatalf("the refusals read %+v", lines)
	}
}

func TestTheLinesAskedForAreBounded(t *testing.T) {
	a := newAgentUnderTest(t, servicesAnswer())
	for _, lines := range []string{"0", "501", "-1", "1e2", "abc", "0100", " 10", "99999999999999999999"} {
		response := a.ask("GET", "/v1/logs?"+url.Values{"service": {"api"}, "lines": {lines}}.Encode(), "")
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatalf("%q lines answered %d", lines, response.StatusCode)
		}
	}
	for _, query := range []string{"service=api", "service=api&lines=10&lines=20", "service=api&lines=10&follow=1"} {
		response := a.ask("GET", "/v1/logs?"+query, "")
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatalf("%q answered %d", query, response.StatusCode)
		}
	}
	if ran := a.ranAnyOf("docker compose logs"); len(ran) != 0 {
		t.Fatalf("logs were read past the bound: %q", ran)
	}
}

func TestTheLogsOfAListedServiceAreReadWithAFixedCommand(t *testing.T) {
	answers := servicesAnswer()
	answers["docker compose logs --no-color --timestamps --tail 500 api"] = "api-1  | 2026-10-29T13:59:59Z started\n"
	a := newAgentUnderTest(t, answers)
	response := a.ask("GET", "/v1/logs?service=api&lines=500", "")
	body := make([]byte, 100)
	n, _ := response.Body.Read(body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body[:n]), "started") {
		t.Fatalf("the logs answered %d: %q", response.StatusCode, body[:n])
	}
	if lines := a.lines(); len(lines) != 1 || lines[0] != (Line{At: "2026-10-29T14:00:00Z", Who: "admin", Action: "read-logs", Result: "ok", Detail: "api"}) {
		t.Fatalf("the read was noted as %+v", lines)
	}
}

func TestAValueSentIsNeverWrittenBackToTheActivity(t *testing.T) {
	a := newAgentUnderTest(t, servicesAnswer())
	secret := "hunter2-hunter2"
	for _, path := range []string{
		"/v1/logs?" + url.Values{"service": {secret}, "lines": {"10"}}.Encode(),
		"/v1/logs?" + url.Values{"service": {"api"}, "lines": {secret}}.Encode(),
		"/v1/activity?limit=" + secret,
		"/v1/status?password=" + secret,
	} {
		a.ask("GET", path, "").Body.Close()
	}
	a.ask("POST", "/v1/activity", `{"who":"admin","action":"sign-in","result":"ok","password":"`+secret+`"}`).Body.Close()
	content, _ := os.ReadFile(a.activity.path)
	if strings.Contains(string(content), secret) || strings.Count(string(content), "\n") != 5 {
		t.Fatalf("the activity reads:\n%s", content)
	}
}

func TestTheConsoleWritesOnlyTheLinesItMay(t *testing.T) {
	a := newAgentUnderTest(t, nil)
	for _, body := range []string{
		`{"who":"admin","action":"restore","result":"ok"}`,
		`{"who":"admin","action":"sign-in","result":"granted"}`,
		`{"who":"Admin; rm","action":"sign-in","result":"ok"}`,
		`{"who":"admin","action":"sign-in","result":"ok","at":"2020-01-01T00:00:00Z"}`,
		`{"who":"admin","action":"sign-in","result":"ok"}{"who":"admin","action":"sign-out","result":"ok"}`,
		`not json`,
	} {
		response := a.ask("POST", "/v1/activity", body)
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatalf("%s answered %d", body, response.StatusCode)
		}
	}
	response := a.ask("POST", "/v1/activity", `{"who":"admin","action":"sign-in","result":"locked"}`)
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("a line the console writes answered %d", response.StatusCode)
	}
	lines := a.lines()
	if len(lines) != 7 || lines[0] != (Line{At: "2026-10-29T14:00:00Z", Who: "admin", Action: "sign-in", Result: "locked"}) {
		t.Fatalf("the activity reads %+v", lines)
	}
	for _, line := range lines[1:] {
		if line.Action != "refused" {
			t.Fatalf("a refused line was kept as %+v", line)
		}
	}
}

func TestTheActivityIsReadNewestFirstAndBounded(t *testing.T) {
	a := newAgentUnderTest(t, nil)
	for _, result := range []string{"refused", "refused", "ok"} {
		a.ask("POST", "/v1/activity", `{"who":"admin","action":"sign-in","result":"`+result+`"}`).Body.Close()
	}
	for _, limit := range []string{"0", "201", "x"} {
		response := a.ask("GET", "/v1/activity?limit="+limit, "")
		response.Body.Close()
		if response.StatusCode != http.StatusForbidden {
			t.Fatalf("a limit of %q answered %d", limit, response.StatusCode)
		}
	}
	response := a.ask("GET", "/v1/activity?limit=4", "")
	var lines []Line
	json.NewDecoder(response.Body).Decode(&lines)
	response.Body.Close()
	if len(lines) != 4 || lines[0].Detail != "GET /v1/activity: limit outside 1 to 200" || lines[3] != (Line{At: "2026-10-29T14:00:00Z", Who: "admin", Action: "sign-in", Result: "ok"}) {
		t.Fatalf("the four newest read as %+v", lines)
	}
}

func TestTheActivityFileIsReadableByRootAlone(t *testing.T) {
	a := newAgentUnderTest(t, nil)
	a.ask("POST", "/v1/activity", `{"who":"admin","action":"sign-out","result":"ok"}`).Body.Close()
	info, err := os.Stat(a.activity.path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the activity is %v (%v)", info.Mode().Perm(), err)
	}
	dir, _ := os.Stat(filepath.Dir(a.activity.path))
	if dir.Mode().Perm() != 0o700 {
		t.Fatalf("its directory is %v", dir.Mode().Perm())
	}
}

func TestTheStatusIsReadWithReadOnlyCommandsOnly(t *testing.T) {
	answers := servicesAnswer()
	answers["docker compose ps --all --format json"] = `{"Service":"caddy","State":"running","Health":"healthy"}
{"Service":"api","State":"running","Health":"starting"}
{"Service":"files-backup","State":"running","Health":""}
`
	answers["docker compose exec -T files-backup restic snapshots --tag files --latest 1 --json"] = `[{"time":"2026-10-29T03:00:12.5+01:00"}]`
	answers["ut-send status"] = "Reporting: off\n"
	a := newAgentUnderTest(t, answers)
	response := a.ask("GET", "/v1/status", "")
	var status Status
	json.NewDecoder(response.Body).Decode(&status)
	response.Body.Close()
	if status.Release != "2026.10.3+abc1234" || status.Model != "qwen3.8-27b-nvfp4" || status.Reporting != "Reporting: off" ||
		status.LastBackup != "2026-10-29T02:00:12Z" || len(status.Disks) != 1 || status.Domain != "box.example.test" {
		t.Fatalf("the status read as %+v", status)
	}
	if len(status.Services) != 3 || status.Services[1] != (Service{"api", "running", "starting", 1, 1}) {
		t.Fatalf("the services read as %+v", status.Services)
	}
	readOnly := []string{
		"docker compose config --services",
		"docker compose ps --all --format json",
		"docker compose exec -T files-backup restic snapshots --tag files --latest 1 --json",
		"ut-send status",
		"ut-license field expires " + machineFile,
	}
	for _, call := range a.fake.called() {
		known := false
		for _, allowed := range readOnly {
			known = known || call == allowed
		}
		if !known {
			t.Fatalf("reading the status ran %q", call)
		}
	}
	if lines := a.lines(); len(lines) != 0 {
		t.Fatalf("reading the status wrote %+v", lines)
	}
}

func TestAServiceWithAReplicaDownIsNotRunning(t *testing.T) {
	services := servicesOf([]string{"workers", "app-builder"}, []container{
		{"workers", "running", "healthy"}, {"workers", "exited", ""},
	})
	if services[0] != (Service{"workers", "exited", "", 2, 1}) || services[1] != (Service{"app-builder", "not created", "", 0, 0}) {
		t.Fatalf("read as %+v", services)
	}
}

func TestTheSocketOpensToItsGroupAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.sock")
	gid := os.Getgid()
	listener, err := listenOn(path, gid)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o660 {
		t.Fatalf("the socket is %v", info.Mode())
	}
	if owner := info.Sys().(*syscall.Stat_t); int(owner.Gid) != gid {
		t.Fatalf("the socket belongs to group %d, not %d", owner.Gid, gid)
	}
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("its group cannot open it: %v", err)
	}
	connection.Close()
}

func TestAStaleSocketIsReplaced(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.sock")
	os.WriteFile(path, nil, 0o666)
	listener, err := listenOn(path, os.Getgid())
	if err != nil {
		t.Fatalf("a socket left by a previous run stopped the agent: %v", err)
	}
	listener.Close()
}

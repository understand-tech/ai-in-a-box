package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestTheCustomersDomainNeverLeavesTheBox(t *testing.T) {
	cases := map[string]string{
		"box.client.example":               "app",
		"llms.box.client.example":          "llms",
		"admin.box.client.example":         "admin",
		"assistants.box.client.example":    "assistants",
		"builder.box.client.example":       "builder",
		"crm.apps.box.client.example":      "apps",
		"other.box.client.example":         "_other",
		"box.client.example.attacker.test": "_other",
		"evilbox.client.example":           "_other",
		"_other":                           "_other",
		"":                                 "_other",
	}
	for host, want := range cases {
		if got := surface(host, "box.client.example"); got != want {
			t.Errorf("%q → %q, want %q", host, got, want)
		}
	}
	if got := surface("llms.box.client.example", ""); got != "_other" {
		t.Errorf("with no known domain, a host became %q", got)
	}
}

func TestOnlyCaddysHostLabelIsRewritten(t *testing.T) {
	dump := `caddy_http_requests_total{handler="subroute",host="llms.box.client.example",server="srv1"} 3 1791449020.214
vllm:num_requests_running{engine="0",host="llms.box.client.example"} 1 1791449020.214
# EOF
`
	want := `caddy_http_requests_total{handler="subroute",host="llms",server="srv1"} 3 1791449020.214
vllm:num_requests_running{engine="0",host="llms.box.client.example"} 1 1791449020.214
# EOF
`
	if got := rewriteSurfaces(dump, "box.client.example"); got != want {
		t.Fatalf("got\n%s", got)
	}
}

func TestExportWindowsResumeAnHourBeforeTheLastAndNeverSpanMoreThanADay(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	windows := usageWindows(now.Add(-3*time.Hour).UnixMilli(), now)
	if len(windows) != 1 || windows[0].from != now.Add(-4*time.Hour).UnixMilli() || windows[0].to != now.UnixMilli() {
		t.Fatalf("windows %+v", windows)
	}
	first := usageWindows(0, now)
	if len(first) != 35 || first[0].from != now.Add(-35*24*time.Hour).UnixMilli() || first[34].to != now.UnixMilli() {
		t.Fatalf("a first export covers %d windows from %d", len(first), first[0].from)
	}
	for _, window := range first {
		if window.to-window.from > dayMillis {
			t.Fatalf("a window spans %d ms", window.to-window.from)
		}
	}
}

func TestTheSameSamplesAlwaysCompressToTheSameBytes(t *testing.T) {
	if !bytes.Equal(gzipped("a 1\n# EOF\n"), gzipped("a 1\n# EOF\n")) {
		t.Fatal("two compressions of one text differ")
	}
}

var usageAnswers = map[string]string{
	"docker ps -aq --filter label=com.docker.compose.project.working_dir=/usr/share/understandtech": "mmmm\ngggg\n",
	"docker inspect":                      "metrics running healthy 0 false mmmm\ncaddy running healthy 0 false gggg\n",
	"docker exec gggg printenv UT_DOMAIN": "box.client.example\n",
	"docker exec mmmm promtool tsdb dump-openmetrics": `caddy_http_requests_total{host="admin.box.client.example"} 3 1791449020.214
# EOF
`,
}

func gunzip(t *testing.T, content []byte) string {
	t.Helper()
	reader, err := gzip.NewReader(bytes.NewReader(content))
	if err != nil {
		t.Fatal(err)
	}
	text, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	return string(text)
}

func TestAnExportIsQueuedWithoutTheDomainAndTheMarkMovesOn(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	saveState(b.place.State, State{LastExported: b.clock.Add(-2 * time.Hour).UnixMilli()})
	var out bytes.Buffer
	if code := runOn([]string{"collect", "usage"}, b.place, machineAnswering(t, usageAnswers), &out, &out); code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	items, _ := listQueue(queueDir(b.place.State))
	if len(items) != 1 || items[0].Kind != "usage" {
		t.Fatalf("queue %+v", items)
	}
	content, _ := os.ReadFile(filepath.Join(queueDir(b.place.State), items[0].Name))
	text := gunzip(t, content)
	if strings.Contains(text, "client.example") || !strings.Contains(text, `host="admin"`) {
		t.Fatalf("export %q", text)
	}
	state, _ := loadState(b.place.State)
	if state.LastExported != b.clock.UnixMilli() {
		t.Fatalf("mark %d, want %d", state.LastExported, b.clock.UnixMilli())
	}
}

func TestAnExportThatFailsKeepsItsWindowForNextTime(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	mark := b.clock.Add(-2 * time.Hour).UnixMilli()
	saveState(b.place.State, State{LastExported: mark})
	answers := map[string]string{
		"docker ps -aq --filter label=com.docker.compose.project.working_dir=/usr/share/understandtech": "mmmm\n",
		"docker inspect": "metrics running healthy 0 false mmmm\n",
	}
	var out bytes.Buffer
	if code := runOn([]string{"collect", "usage"}, b.place, machineAnswering(t, answers), &out, &out); code == 0 {
		t.Fatal("a failed dump was reported as done")
	}
	if state, _ := loadState(b.place.State); state.LastExported != mark {
		t.Fatalf("the mark moved to %d after a failure", state.LastExported)
	}
	if b.waiting(t) != 0 {
		t.Fatal("something was queued from a failed dump")
	}
}

func TestAWindowWithNoSampleQueuesNothingButMovesOn(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	saveState(b.place.State, State{LastExported: b.clock.Add(-2 * time.Hour).UnixMilli()})
	answers := map[string]string{}
	for k, v := range usageAnswers {
		answers[k] = v
	}
	answers["docker exec mmmm promtool tsdb dump-openmetrics"] = "# EOF\n"
	var out bytes.Buffer
	if code := runOn([]string{"collect", "usage"}, b.place, machineAnswering(t, answers), &out, &out); code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	if b.waiting(t) != 0 {
		t.Fatal("an empty export was queued")
	}
	if state, _ := loadState(b.place.State); state.LastExported != b.clock.UnixMilli() {
		t.Fatal("the mark did not move past an empty window")
	}
}

func TestABoxWithoutARecorderExportsNothing(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	answers := map[string]string{
		"docker ps -aq --filter label=com.docker.compose.project.working_dir=/usr/share/understandtech": "gggg\n",
		"docker inspect": "caddy running healthy 0 false gggg\n",
	}
	var out bytes.Buffer
	if code := runOn([]string{"collect", "usage"}, b.place, machineAnswering(t, answers), &out, &out); code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	if b.waiting(t) != 0 || !reflect.DeepEqual(strings.TrimSpace(out.String()), "ut-send: no recorder runs here; nothing to export") {
		t.Fatalf("out %q", out.String())
	}
}

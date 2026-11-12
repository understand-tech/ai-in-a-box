package main

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

// usageSeries is `{__name__=~"PATTERN"}` — extracted and tested with the same
// regexp engine (RE2) Prometheus itself matches series names with, not a
// hand-rolled approximation of what the selector does.
func TestUsageSeriesKeepsTheNewCostMetricAlongsideInference(t *testing.T) {
	start := strings.Index(usageSeries, `"`) + 1
	end := strings.LastIndex(usageSeries, `"`)
	pattern := regexp.MustCompile("^(?:" + usageSeries[start:end] + ")$")

	for _, name := range []string{
		"ut_inference_requests_total",
		"ut_cost_usd_total",
		"ut_cost_gpu_seconds_total",
		"vllm:num_requests_running",
		"caddy_http_requests_total",
	} {
		if !pattern.MatchString(name) {
			t.Errorf("usageSeries should keep %q, does not", name)
		}
	}
	if pattern.MatchString("some_other_metric") {
		t.Errorf("usageSeries should not keep an unrelated metric name, does")
	}
}

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
	if got, err := rewriteSurfaces(dump, "box.client.example"); err != nil || got != want {
		t.Fatalf("got\n%s, error %v", got, err)
	}
}

func TestCollapsedHostContributionsAreAddedAndSorted(t *testing.T) {
	for metric := range additiveCaddySeries {
		for _, category := range []struct{ host1, host2, surface string }{
			{"one.apps.box.client.example", "two.apps.box.client.example", "apps"},
			{"one.box.client.example", "two.box.client.example", "_other"},
		} {
			t.Run(metric+"/"+category.surface, func(t *testing.T) {
				dump := fmt.Sprintf(`%[1]s{server="srv1",host="%[2]s",method="GET"} 4 1791449021.214
%[1]s{method="GET",host="%[3]s",server="srv1"} 4 1791449020.214
%[1]s{server="srv1",host="%[2]s",method="GET"} 3 1791449020.214
%[1]s{method="GET",host="%[3]s",server="srv1"} 4 1791449021.214
# EOF
`, metric, category.host1, category.host2)
				want := fmt.Sprintf(`%[1]s{host="%[2]s",method="GET",server="srv1"} 7 1791449020.214
%[1]s{host="%[2]s",method="GET",server="srv1"} 8 1791449021.214
# EOF
`, metric, category.surface)
				got, err := rewriteSurfaces(dump, "box.client.example")
				if err != nil || got != want {
					t.Fatalf("got %q, error %v; want %q", got, err, want)
				}
				if strings.Contains(got, "client.example") {
					t.Fatal("an original host escaped anonymization")
				}
			})
		}
	}
}

func TestCollapsedHostsPreserveUnknownAndInfiniteUsageValues(t *testing.T) {
	for _, test := range []struct{ name, left, right, want string }{
		{"unknown", "NaN", "2", "NaN"},
		{"positive infinity", "+Inf", "2", "+Inf"},
		{"negative infinity", "-Inf", "2", "-Inf"},
		{"overflow", "1e308", "1e308", "+Inf"},
	} {
		t.Run(test.name, func(t *testing.T) {
			dump := fmt.Sprintf(`caddy_http_request_duration_seconds_sum{host="one.box.example"} %s 10
caddy_http_request_duration_seconds_sum{host="two.box.example"} %s 10
# EOF
`, test.left, test.right)
			want := fmt.Sprintf("caddy_http_request_duration_seconds_sum{host=\"_other\"} %s 10\n# EOF\n", test.want)
			if got, err := rewriteSurfaces(dump, "box.example"); err != nil || got != want {
				t.Fatalf("got %q, error %v; want %q", got, err, want)
			}
		})
	}
}

func TestUsageKeepsDistinctLabelsAndUnrelatedValues(t *testing.T) {
	dump := `vllm:num_requests_running{engine="0"} 1.250 1791449021.214
caddy_http_requests_total{host="one.box.client.example",method="POST"} 2 1791449020.214
caddy_http_requests_total{host="two.box.client.example",method="GET"} 3 1791449020.214
caddy_admin_config_last_reload_successful 1.0 1791449020.214
vllm:num_requests_running{engine="0"} 0.500 1791449020.214
vllm:num_requests_running{engine="0"} 0.500 1791449020.214
# EOF
`
	want := `caddy_admin_config_last_reload_successful 1.0 1791449020.214
caddy_http_requests_total{host="_other",method="GET"} 3 1791449020.214
caddy_http_requests_total{host="_other",method="POST"} 2 1791449020.214
vllm:num_requests_running{engine="0"} 0.500 1791449020.214
vllm:num_requests_running{engine="0"} 1.250 1791449021.214
# EOF
`
	if got, err := rewriteSurfaces(dump, "box.client.example"); err != nil || got != want {
		t.Fatalf("got %q, error %v; want %q", got, err, want)
	}
}

func TestUnsupportedUsageExportsAreRefused(t *testing.T) {
	for name, dump := range map[string]string{
		"missing EOF":        "vllm:requests 1 1791449020\n",
		"after EOF":          "# EOF\nvllm:requests 1 1791449020\n",
		"metadata":           "# TYPE vllm:requests gauge\n# EOF\n",
		"missing timestamp":  "vllm:requests 1\n# EOF\n",
		"invalid timestamp":  "vllm:requests 1 NaN\n# EOF\n",
		"hexadecimal":        "vllm:requests 0x1p2 1791449020\n# EOF\n",
		"exemplar":           "vllm:requests 1 1791449020 # {trace_id=\"id\"} 1\n# EOF\n",
		"duplicate labels":   "vllm:requests{engine=\"0\",engine=\"1\"} 1 1791449020\n# EOF\n",
		"invalid escape":     `vllm:requests{engine="\t"} 1 1791449020` + "\n# EOF\n",
		"trailing comma":     "vllm:requests{engine=\"0\",} 1 1791449020\n# EOF\n",
		"conflicting engine": "vllm:requests 1 1791449020\nvllm:requests 2 1791449020\n# EOF\n",
		"non additive host":  "caddy_unknown{host=\"one.box.client.example\"} 1 1791449020\ncaddy_unknown{host=\"two.box.client.example\"} 2 1791449020\n# EOF\n",
		"conflicting source": "caddy_http_requests_total{host=\"one.box.client.example\"} 1 1791449020\ncaddy_http_requests_total{host=\"one.box.client.example\"} 2 1791449020\n# EOF\n",
	} {
		t.Run(name, func(t *testing.T) {
			if got, err := rewriteSurfaces(dump, "box.client.example"); err == nil || got != "" {
				t.Fatalf("invalid export accepted: %q, error %v", got, err)
			}
		})
	}
}

func TestRejectedUsageExportKeepsItsMarkAndQueuesNothing(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	mark := b.clock.Add(-2 * time.Hour).UnixMilli()
	saveState(b.place.State, State{LastExported: mark})
	answers := map[string]string{}
	for command, answer := range usageAnswers {
		answers[command] = answer
	}
	answers["docker exec mmmm promtool tsdb dump-openmetrics"] = "vllm:requests 1 1791449020\nvllm:requests 2 1791449020\n# EOF\n"
	var out bytes.Buffer
	if code := runOn([]string{"collect", "usage"}, b.place, machineAnswering(t, answers), &out, &out); code == 0 {
		t.Fatal("a conflicting export was reported as done")
	}
	if state, _ := loadState(b.place.State); state.LastExported != mark {
		t.Fatalf("the mark moved to %d after a validation failure", state.LastExported)
	}
	if b.waiting(t) != 0 {
		t.Fatal("something was queued from an invalid export")
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

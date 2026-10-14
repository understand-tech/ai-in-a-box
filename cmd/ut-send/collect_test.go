package main

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const inspected = `api running healthy 0 false aaaa
worker running healthy 2 false bbbb
worker running unhealthy 1 true cccc
mongodb running weird 0 false dddd
redis running healthy 0 false eeee
nim-llm running healthy 0 false ffff
caddy running healthy 0 false gggg
mongodb-backup running healthy 0 false hhhh
`

const baseReportJSON = `{"schema": 1, "generated_at": "2026-10-14T12:00:00Z", "install_id": "1ac8db8c48d58ae62639a40a843c0ec6",
"window_days": 30, "release": "2026.10.0", "images": [], "capacity": [], "users_by_hour": [],
"memory": {"host": {"total_bytes": 1, "available_bytes": 1}, "services": []}, "history": [], "warnings": ["recorder-unreachable"]}`

// A stand-in for the machine's commands, answered by the start of the command line.
func fakeRunner(t *testing.T, answers map[string]string) Runner {
	return func(dir, name string, args ...string) (string, error) {
		line := strings.Join(append([]string{name}, args...), " ")
		if name == "ut-report" {
			report := filepath.Join(args[1], "ut-report-20261014T1200Z")
			if err := os.MkdirAll(report, 0o700); err != nil {
				t.Fatal(err)
			}
			return "", os.WriteFile(filepath.Join(report, "report.json"), []byte(baseReportJSON), 0o600)
		}
		for prefix, answer := range answers {
			if strings.HasPrefix(line, prefix) {
				return answer, nil
			}
		}
		return "", errors.New("not answered: " + line)
	}
}

func machineAnswering(t *testing.T, answers map[string]string) machine {
	return machine{
		run:        fakeRunner(t, answers),
		installDir: "/usr/share/understandtech",
		space: func(path string) (uint64, int64, int64, bool) {
			return map[string]uint64{"/": 1, "/var/lib/docker": 1, dataRoot: 2}[path], 1000, 400, true
		},
		ownerOf: func(pid string) string { return map[string]string{"41": "ffff"}[pid] },
		ingress: func(string) *x509.Certificate { return nil },
	}
}

var everyAnswer = map[string]string{
	"docker ps -aq --filter label=com.docker.compose.project=understandtech": "aaaa\nbbbb\ncccc\ndddd\neeee\nffff\ngggg\nhhhh\n",
	"docker inspect": inspected,
	"docker exec eeee redis-cli SMEMBERS rq:queues":      "rq:queue:default\n",
	"docker exec eeee redis-cli LLEN rq:queue:default":   "3\n",
	"docker exec eeee redis-cli ZCARD rq:failed:default": "1\n",
	"docker exec eeee redis-cli SCARD rq:workers":        "4\n",
	"docker info": "/var/lib/docker\n",
	"nvidia-smi":  "41, 87844\n99, 10\n",
	"docker exec ffff curl -sf --max-time 5 http://127.0.0.1:8000/v1/models": `{"data": [{"id": "qwen"}]}`,
	"docker exec ffff printenv NIM_SERVED_MODEL_NAME":                        "qwen\n",
	"docker exec ffff curl -sf --max-time 5 http://127.0.0.1:8000/metrics":   "vllm:request_success_total{finished_reason=\"stop\"} 10.0\nvllm:request_success_total{finished_reason=\"length\"} 2.0\n",
	"docker exec ffff sh -c":              "model: Qwen3.8-27B-NVFP4\n/models/Qwen3.8-27B-NVFP4\n",
	"docker exec hhhh sh -c":              "1760436000\n",
	"docker exec gggg printenv UT_DOMAIN": "box.example.test\n",
	"timedatectl":                         "yes\n",
	"docker exec dddd mongosh":            "Using MongoDB\n" + `{"requests_by_hour": [{"hour": 7200, "source": "chat", "app": "app", "requests": 2}, {"hour": 3600, "source": "gateway", "app": "llms", "requests": 5}], "users_7d": [{"source": "any", "app": "any", "users": 3}]}`,
}

func TestTheHealthOfTheStackIsReadTheWayThePrototypeReadIt(t *testing.T) {
	health, warnings := machineAnswering(t, everyAnswer).health()

	wantServices := []Service{
		{"api", 1, 1, "healthy", 0, false},
		{"caddy", 1, 1, "healthy", 0, false},
		{"mongodb", 1, 1, "none", 0, false},
		{"mongodb-backup", 1, 1, "healthy", 0, false},
		{"nim-llm", 1, 1, "healthy", 0, false},
		{"redis", 1, 1, "healthy", 0, false},
		{"worker", 2, 2, "unhealthy", 3, true},
	}
	if !reflect.DeepEqual(health.Services, wantServices) {
		t.Fatalf("services %+v", health.Services)
	}
	if !reflect.DeepEqual(health.Queues, []Queue{{"default", 3, 1}}) || health.Workers == nil || *health.Workers != 4 {
		t.Fatalf("queues %+v workers %v", health.Queues, health.Workers)
	}
	if len(health.Disks) != 2 || health.Disks[0].Path != "/" || health.Disks[1].Path != dataRoot {
		t.Fatalf("disks on the same device were not counted once: %+v", health.Disks)
	}
	engine := health.Engines[0]
	if engine.Service != "nim-llm" || *engine.Requests != 12 || *engine.GPUMemoryBytes != 87844*1024*1024 ||
		*engine.CachedModel != "Qwen3.8-27B-NVFP4" || *engine.ModelPath != "/models/Qwen3.8-27B-NVFP4" ||
		*engine.DeclaredModel != "qwen" || !reflect.DeepEqual(engine.ServedModels, []string{"qwen"}) {
		t.Fatalf("engine %+v", engine)
	}
	if len(health.Backups) != 1 || *health.Backups[0].LastAt != utc(time.Unix(1760436000, 0)) {
		t.Fatalf("backups %+v", health.Backups)
	}
	if health.NTPSynchronized == nil || !*health.NTPSynchronized {
		t.Fatal("the clock was not read as synchronised")
	}
	if !reflect.DeepEqual(warnings, []string{"health-unreadable:certificate:ingress"}) {
		t.Fatalf("warnings %v", warnings)
	}
}

func TestAnUnreadableSourceIsNamedNotGuessed(t *testing.T) {
	answers := map[string]string{
		"docker ps -aq --filter label=com.docker.compose.project=understandtech": "ffff\nhhhh\n",
		"docker inspect": "nim-llm running healthy 0 false ffff\nmongodb-backup running healthy 0 false hhhh\n",
	}
	health, warnings := machineAnswering(t, answers).health()
	if health.Workers != nil || health.NTPSynchronized != nil {
		t.Fatal("a value nobody could read was filled in")
	}
	want := []string{"health-unreadable:engine:nim-llm", "health-unreadable:backup:mongodb"}
	if !reflect.DeepEqual(warnings, want) {
		t.Fatalf("warnings %v, want %v", warnings, want)
	}
}

func TestToolCountsComeOutSortedAndOnlyAsNumbers(t *testing.T) {
	tools, warnings := machineAnswering(t, everyAnswer).tools(30)
	if len(warnings) != 0 {
		t.Fatalf("warnings %v", warnings)
	}
	if tools.RequestsByHour[0].Hour != 3600 || tools.RequestsByHour[1].Hour != 7200 || tools.Users7d[0].Users != 3 {
		t.Fatalf("tools %+v", tools)
	}
	if !strings.Contains(countingScript(30), "const DAYS = 30, PEOPLE_DAYS = 7") {
		t.Fatal("the window is not handed to the database")
	}
}

func TestADatabaseThatCannotBeCountedIsNamed(t *testing.T) {
	answers := map[string]string{"docker ps -aq --filter label=com.docker.compose.project=understandtech": "dddd\n", "docker inspect": "mongodb running healthy 0 false dddd\n"}
	tools, warnings := machineAnswering(t, answers).tools(30)
	if len(tools.RequestsByHour) != 0 || !reflect.DeepEqual(warnings, []string{"tools-unreadable:mongodb"}) {
		t.Fatalf("tools %+v warnings %v", tools, warnings)
	}
}

func TestCollectQueuesUtReportsReportWithHealthAndTools(t *testing.T) {
	b := newBox(t, newFakeReceiver(t))
	var out bytes.Buffer
	if code := runOn([]string{"collect", "report"}, b.place, machineAnswering(t, everyAnswer), &out, &out); code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	items, _ := listQueue(queueDir(b.place.State))
	if len(items) != 1 || items[0].Kind != "report" {
		t.Fatalf("queue %+v", items)
	}
	content, _ := os.ReadFile(filepath.Join(queueDir(b.place.State), items[0].Name))
	var report map[string]any
	if err := json.Unmarshal(content, &report); err != nil {
		t.Fatal(err)
	}
	if report["schema"] != float64(3) || report["health"] == nil || report["tools"] == nil || report["release"] != "2026.10.0" {
		t.Fatalf("report %v", report)
	}
	warnings := report["warnings"].([]any)
	if len(warnings) != 2 || warnings[0] != "health-unreadable:certificate:ingress" || warnings[1] != "recorder-unreachable" {
		t.Fatalf("warnings %v", warnings)
	}
	if entries, _ := os.ReadDir(b.place.State); len(entries) > 3 {
		t.Fatalf("collect left files behind: %v", entries)
	}
}

func TestNothingIsCollectedWithoutAYes(t *testing.T) {
	b := newBox(t, nil)
	var out bytes.Buffer
	if code := runOn([]string{"collect", "report"}, b.place, machineAnswering(t, everyAnswer), &out, &out); code == 0 {
		t.Fatal("collected with no answer given")
	}
}

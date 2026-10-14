package main

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func (b *box) unit(t *testing.T, name string) string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(b.place.Units, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func TestAYesStartsATimerEveryFifteenMinutes(t *testing.T) {
	b := newBox(t, nil)
	b.must(t, "configure", "--consent", "yes")
	if !strings.Contains(b.unit(t, timerName), "OnUnitActiveSec=15min") {
		t.Fatalf("timer:\n%s", b.unit(t, timerName))
	}
	service := b.unit(t, serviceName)
	for _, line := range []string{
		`ExecStart="/usr/lib/understandtech/ut-send-linux-arm64" tick`,
		`Environment="UT_SEND_SETTINGS=` + b.place.Settings + `"`,
		`Environment="UT_SEND_STATE=` + b.place.State + `"`,
	} {
		if !strings.Contains(service, line) {
			t.Fatalf("service lacks %q:\n%s", line, service)
		}
	}
	want := []string{"daemon-reload", "enable ut-send.timer", "restart ut-send.timer"}
	if !reflect.DeepEqual(b.systemd.asked, want) {
		t.Fatalf("systemctl asked %q, want %q", b.systemd.asked, want)
	}
	if _, out := b.call("status"); strings.Contains(out, "no timer") {
		t.Fatalf("a running timer reported missing: %s", out)
	}
}

func TestThePeriodCanBeChangedAndIsKept(t *testing.T) {
	b := newBox(t, nil)
	b.must(t, "configure", "--consent", "yes", "--every", "5")
	b.must(t, "configure", "--consent", "yes", "--receiver", "https://receiver.example.test:8444")
	if !strings.Contains(b.unit(t, timerName), "OnUnitActiveSec=5min") {
		t.Fatalf("timer:\n%s", b.unit(t, timerName))
	}
	if b.systemd.asked[len(b.systemd.asked)-1] != "restart ut-send.timer" {
		t.Fatalf("a changed period was not applied: %q", b.systemd.asked)
	}
	if settings, _, _ := loadSettings(b.place.Settings); settings.every() != 5 {
		t.Fatalf("the period was not kept: %d", settings.every())
	}
}

func TestAPeriodThatMeansNothingIsRefused(t *testing.T) {
	b := newBox(t, nil)
	for _, every := range []string{"0", "-5", "1441", "ten"} {
		if code, _ := b.call("configure", "--consent", "yes", "--every", every); code != 2 {
			t.Errorf("--every %s: exit %d, want 2", every, code)
		}
	}
	if _, err := os.Stat(b.place.Settings); !os.IsNotExist(err) {
		t.Fatalf("a refused period wrote the settings: %v", err)
	}
	if len(b.systemd.asked) != 0 {
		t.Fatalf("a refused period touched systemd: %q", b.systemd.asked)
	}
}

func TestANoStopsTheTimerAndEmptiesTheLine(t *testing.T) {
	b := newBox(t, nil)
	b.must(t, "configure", "--consent", "yes")
	b.enqueue(t, "report", "written while the answer was yes")
	b.must(t, "configure", "--consent", "no")
	if b.waiting(t) != 0 {
		t.Fatal("what was in line outlived the no")
	}
	for _, name := range []string{timerName, serviceName} {
		if _, err := os.Stat(filepath.Join(b.place.Units, name)); !os.IsNotExist(err) {
			t.Fatalf("%s outlived the no: %v", name, err)
		}
	}
	if b.systemd.running {
		t.Fatal("the timer still runs after a no")
	}
	if got := b.systemd.asked[len(b.systemd.asked)-2:]; !reflect.DeepEqual(got, []string{"disable --now ut-send.timer", "daemon-reload"}) {
		t.Fatalf("systemctl asked %q", got)
	}
}

func TestAYesTheTimerCannotFollowIsKeptAndSaidSo(t *testing.T) {
	b := newBox(t, nil)
	b.systemd.broken = true
	code, out := b.call("configure", "--consent", "yes")
	if code != 1 || !strings.Contains(out, "the timer could not follow it") {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got := statusOf(b); !strings.HasPrefix(got, "Reporting: on") {
		t.Fatalf("the answer was not kept: %q", got)
	}
	if _, out := b.call("status"); !strings.Contains(out, "no timer runs it") {
		t.Fatalf("a missing timer went unsaid: %s", out)
	}
}

// One machine for both: the commands the report reads, and systemctl.
func (b *box) machineWith(t *testing.T, answers map[string]string) machine {
	m := machineAnswering(t, answers)
	answer := m.run
	m.run = func(dir, name string, args ...string) (string, error) {
		if name == "systemctl" {
			return b.systemd.run(dir, name, args...)
		}
		return answer(dir, name, args...)
	}
	return m
}

func (b *box) tick(t *testing.T, m machine) int {
	t.Helper()
	var out strings.Builder
	return runOn([]string{"tick"}, b.place, m, &out, &out)
}

func TestATickReportsOnceAnHourAndSendsEachTime(t *testing.T) {
	receiver := newFakeReceiver(t)
	b := newBox(t, receiver)
	m := b.machineWith(t, everyAnswer)
	if code := b.tick(t, m); code != 0 {
		t.Fatalf("first tick: exit %d", code)
	}
	b.clock = b.clock.Add(15 * time.Minute)
	b.enqueue(t, "usage", "between two reports")
	b.tick(t, m)
	b.clock = b.clock.Add(45 * time.Minute)
	b.tick(t, m)
	var paths []string
	for _, d := range receiver.received() {
		paths = append(paths, d.path)
	}
	if want := []string{"/reports", "/conso", "/reports"}; !reflect.DeepEqual(paths, want) {
		t.Fatalf("deposits %q, want %q", paths, want)
	}
}

func TestATickWithoutAYesDoesNothing(t *testing.T) {
	b := newBox(t, nil)
	b.must(t, "configure", "--consent", "no")
	if code := b.tick(t, b.machineWith(t, everyAnswer)); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if entries, _ := os.ReadDir(b.place.State); len(entries) != 0 {
		t.Fatalf("a tick without a yes left %v", entries)
	}
}

func TestAReportThatFailsDoesNotHoldBackTheSends(t *testing.T) {
	receiver := newFakeReceiver(t)
	b := newBox(t, receiver)
	b.enqueue(t, "usage", "already in line")
	m := b.machineWith(t, everyAnswer)
	answer := m.run
	m.run = func(dir, name string, args ...string) (string, error) {
		if name == "ut-report" {
			return "", errors.New("exit status 1")
		}
		return answer(dir, name, args...)
	}
	if code := b.tick(t, m); code != 1 {
		t.Fatalf("a failed report went unsaid: exit %d", code)
	}
	if got := receiver.received(); len(got) != 1 || got[0].path != "/conso" {
		t.Fatalf("deposits %+v", got)
	}
	b.clock = b.clock.Add(time.Minute)
	b.tick(t, b.machineWith(t, everyAnswer))
	if got := receiver.received(); len(got) != 2 || got[1].path != "/reports" {
		t.Fatalf("the report was not tried again on the next tick: %+v", got)
	}
}

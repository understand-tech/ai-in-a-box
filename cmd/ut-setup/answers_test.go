package main

import (
	"io"
	"net/url"
	"strings"
	"testing"
)

func TestAValueIsReadAsUtInstallReadsIt(t *testing.T) {
	settings := "  ADMIN_SETUP_PASSWORD=\"quoted\"\nBACKUP_FILES_PASSWORD='single'\nBACKUP_FILES_PASSWORD=\"second\"\nOTHER=x\n"
	if got := settingValue(settings, "ADMIN_SETUP_PASSWORD"); got != "quoted" {
		t.Fatalf("double quotes read as %q", got)
	}
	if got := settingValue(settings, "BACKUP_FILES_PASSWORD"); got != "single" {
		t.Fatalf("the first assignment read as %q", got)
	}
	if got := settingValue(settings, "ABSENT"); got != "" {
		t.Fatalf("an absent key read as %q", got)
	}
}

func TestUtGetsFolderReachesUtSetup(t *testing.T) {
	installer, folder, err := parseSetup([]string{"--images-from", "/media/box", "--machine-file", "/media/box/box.lic"}, io.Discard)
	if err != nil || installer != "ut-install" || folder != (Folder{Images: "/media/box", License: "/media/box/box.lic"}) {
		t.Fatalf("read as %q, %+v, %v", installer, folder, err)
	}
	if _, _, err := parseSetup([]string{"--domain", "box.example.com"}, io.Discard); err == nil {
		t.Fatal("an option the page asks for was taken from the command line")
	}
}

func TestAFolderTakesTheKeyAndTheReportsOffThePage(t *testing.T) {
	form := url.Values{"domain": {"box.example.com"}, "license": {"typed-anyway"}, "reporting": {"yes"}}
	answers, err := parseAnswers(form, Folder{Images: "/media/box", License: "/media/box/box.lic"})
	if err != nil || answers.License != "" || answers.Reporting != "no" {
		t.Fatalf("from a folder that carries the license, read as %+v, %v", answers, err)
	}
	form.Del("license")
	if _, err := parseAnswers(form, Folder{Images: "/media/box"}); err == nil {
		t.Fatal("a folder without the license file went on without a key")
	}
}

func TestAnAddressIsTakenInLowerCase(t *testing.T) {
	answers, err := parseAnswers(url.Values{"domain": {" IA.Example.FR "}, "license": {"k"}, "reporting": {"yes"}}, Folder{})
	if err != nil || answers.Domain != "ia.example.fr" {
		t.Fatalf("read as %+v, %v", answers, err)
	}
}

func TestTheBrowserOpensInTheSessionOfWhoeverRanSudo(t *testing.T) {
	got := strings.Join(browserCommand("operator", []string{"DISPLAY=:1"}, "x-www-browser", "http://127.0.0.1:4242/?code=x"), " ")
	want := "runuser -u operator -- env DISPLAY=:1 x-www-browser http://127.0.0.1:4242/?code=x"
	if got != want {
		t.Fatalf("opened with %q", got)
	}
}

func TestTheSessionIsReadFromAGraphicalProcess(t *testing.T) {
	gdm := []byte("HOME=/home/ut\x00DISPLAY=:1\x00XAUTHORITY=/run/user/1000/gdm/Xauthority\x00DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\x00SECRET=x\x00")
	got := strings.Join(sessionVariables(gdm), " ")
	if got != "DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" {
		t.Fatalf("read %q", got)
	}
	if session := sessionVariables([]byte("HOME=/home/ut\x00DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\x00")); session != nil {
		t.Fatalf("a process with no display was taken for the desktop: %q", session)
	}
}

func TestAnImageIsCountedFromItsEventOnly(t *testing.T) {
	p := Progress{}.apply(Event{V: eventsVersion, Event: "image", Landed: 2, Name: "ghcr.io/x/api:1"})
	if p.Landed != 2 || p.Total != 0 {
		t.Fatalf("an unknown total read as %+v", p)
	}
	p = Progress{}.read("     3/4  ghcr.io/x/api:1  (5 min)")
	if p.Landed != 0 {
		t.Fatalf("a line of text moved the count: %+v", p)
	}
}

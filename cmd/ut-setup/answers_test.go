package main

import (
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

func TestAnAddressIsTakenInLowerCase(t *testing.T) {
	answers, err := parseAnswers(url.Values{"domain": {" IA.Example.FR "}, "license": {"k"}, "reporting": {"yes"}})
	if err != nil || answers.Domain != "ia.example.fr" {
		t.Fatalf("read as %+v, %v", answers, err)
	}
}

func TestTheBrowserOpensInTheSessionOfWhoeverRanSudo(t *testing.T) {
	got := strings.Join(browserCommand("mathieu", "1000", "http://127.0.0.1:4242/?code=x"), " ")
	want := "runuser -u mathieu -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 xdg-open http://127.0.0.1:4242/?code=x"
	if got != want {
		t.Fatalf("opened with %q", got)
	}
}

func TestAnImageLineIsReadOnlyWhenItIsOne(t *testing.T) {
	p := Progress{}.read("     2/?  ghcr.io/x/api:1  (0 min)")
	if p.Landed != 2 || p.Total != 0 {
		t.Fatalf("an unknown total read as %+v", p)
	}
	p = Progress{}.read("The image 3/4 was big (5 min)")
	if p.Landed != 0 {
		t.Fatalf("a sentence read as an image: %+v", p)
	}
}

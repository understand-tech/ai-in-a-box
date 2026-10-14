package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestStatusSaysReportingIsOffUntilSomeoneTurnsItOn(t *testing.T) {
	var out bytes.Buffer
	code := run([]string{"status"}, &out, &out)
	if code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	if got := strings.TrimSpace(out.String()); got != "Reporting: off" {
		t.Fatalf("status = %q, want %q", got, "Reporting: off")
	}
}

func TestAnUnknownCommandIsRefused(t *testing.T) {
	var out bytes.Buffer
	if code := run([]string{"launch"}, &out, &out); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if !strings.Contains(out.String(), "usage: ut-send") {
		t.Fatalf("no usage in %q", out.String())
	}
}

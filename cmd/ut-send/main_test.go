package main

import (
	"strings"
	"testing"
)

func TestAnUnknownCommandIsRefused(t *testing.T) {
	code, out := newBox(t, nil).call("launch")
	if code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if !strings.Contains(out, "usage: ut-send") {
		t.Fatalf("no usage in %q", out)
	}
}

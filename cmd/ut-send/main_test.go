package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestAnUnknownCommandIsRefused(t *testing.T) {
	var out bytes.Buffer
	if code := run([]string{"launch"}, filepath.Join(t.TempDir(), "reporting.json"), &out, &out); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if !strings.Contains(out.String(), "usage: ut-send") {
		t.Fatalf("no usage in %q", out.String())
	}
}

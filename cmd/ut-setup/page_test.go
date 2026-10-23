package main

import (
	"regexp"
	"testing"
)

var (
	declaredVariable = regexp.MustCompile(`(--[\w-]+)\s*:`)
	usedVariable     = regexp.MustCompile(`var\(\s*(--[\w-]+)`)
	hiddenHides      = regexp.MustCompile(`\[hidden\]\s*\{\s*display:\s*none\s*!important;?\s*\}`)
)

func sheet(t *testing.T, name string) []byte {
	t.Helper()
	content, err := page.ReadFile("page/" + name)
	if err != nil {
		t.Fatalf("the page carries no %s: %v", name, err)
	}
	return content
}

func TestEveryColourThePageAsksForIsDeclared(t *testing.T) {
	declared := map[string]bool{}
	for _, name := range []string{"tokens.css", "style.css"} {
		for _, match := range declaredVariable.FindAllSubmatch(sheet(t, name), -1) {
			declared[string(match[1])] = true
		}
	}
	for _, match := range usedVariable.FindAllSubmatch(sheet(t, "style.css"), -1) {
		if !declared[string(match[1])] {
			t.Errorf("style.css asks for %s, which neither tokens.css nor style.css declares", match[1])
		}
	}
}

func TestAHiddenElementStaysHiddenWhateverItsStyle(t *testing.T) {
	if !hiddenHides.Match(sheet(t, "style.css")) {
		t.Error("style.css no longer forces [hidden] to display: none !important — a styled block would show through")
	}
}

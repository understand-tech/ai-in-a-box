package main

import (
	"regexp"
	"testing"
)

var (
	declaredVariable = regexp.MustCompile(`(--[\w-]+)\s*:`)
	usedVariable     = regexp.MustCompile(`var\(\s*(--[\w-]+)`)
	hiddenHides      = regexp.MustCompile(`\[hidden\]\s*\{\s*display:\s*none\s*!important;?\s*\}`)
	scriptTag        = regexp.MustCompile(`<script[^>]*>`)
	scriptFromAFile  = regexp.MustCompile(`\ssrc="/page/[a-z-]+\.js"`)
	inlineAttribute  = regexp.MustCompile(`\s(on[a-z]+|style)\s*=`)
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
	for _, name := range []string{"tokens.css", "style.css", "console.css"} {
		for _, match := range declaredVariable.FindAllSubmatch(sheet(t, name), -1) {
			declared[string(match[1])] = true
		}
	}
	for _, name := range []string{"style.css", "console.css"} {
		for _, match := range usedVariable.FindAllSubmatch(sheet(t, name), -1) {
			if !declared[string(match[1])] {
				t.Errorf("%s asks for %s, which no sheet declares", name, match[1])
			}
		}
	}
}

func TestAHiddenElementStaysHiddenWhateverItsStyle(t *testing.T) {
	if !hiddenHides.Match(sheet(t, "style.css")) {
		t.Error("style.css no longer forces [hidden] to display: none !important — a styled block would show through")
	}
}

// The policy refuses inline scripts and styles: one written here would not run,
// and the page would break without a word.
func TestThePagesCarryNoInlineScriptOrStyle(t *testing.T) {
	for _, name := range []string{"index.html", "sign-in.html"} {
		html := sheet(t, name)
		for _, tag := range scriptTag.FindAll(html, -1) {
			if !scriptFromAFile.Match(tag) {
				t.Errorf("%s carries %s, a script of its own, which the policy blocks", name, tag)
			}
		}
		if match := inlineAttribute.Find(html); match != nil {
			t.Errorf("%s carries %q, which the policy blocks", name, match)
		}
	}
}

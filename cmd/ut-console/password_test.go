package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestThePasswordIsHashedFromTheStandardInputOnly(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run([]string{"hash-password"}, strings.NewReader(rightPassword+"\n"), &stdout, &stderr); code != 0 {
		t.Fatalf("hash-password exited %d: %s", code, stderr.String())
	}
	stored := strings.TrimSpace(stdout.String())
	if strings.Contains(stored, rightPassword) || !passwordMatches(stored, rightPassword) || passwordMatches(stored, rightPassword+"x") {
		t.Fatalf("the hash %q does not stand for the password", stored)
	}
	fields := strings.Split(stored, "$")
	if fields[0] != "pbkdf2-sha256" || fields[1] != "600000" || len(fields[2]) != 22 {
		t.Fatalf("hashed as %q, not PBKDF2-HMAC-SHA256 at 600 000 rounds with 16 bytes of salt", stored)
	}
	again := &bytes.Buffer{}
	run([]string{"hash-password"}, strings.NewReader(rightPassword+"\n"), again, &stderr)
	if strings.TrimSpace(again.String()) == stored {
		t.Fatal("the same password hashed twice gave the same hash: the salt is not drawn")
	}
	for _, given := range [][]string{{"hash-password", rightPassword}, {"hash-password", "--password", rightPassword}} {
		stdout.Reset()
		if code := run(given, strings.NewReader(""), &stdout, &stderr); code != 2 || stdout.Len() != 0 {
			t.Fatalf("a password given as an argument was taken: exit %d, %q", code, stdout.String())
		}
	}
	for _, input := range []string{"", "\n", strings.Repeat("x", 2000) + "\n"} {
		stdout.Reset()
		if code := run([]string{"hash-password"}, strings.NewReader(input), &stdout, &stderr); code == 0 {
			t.Fatalf("%d bytes on the standard input were hashed", len(input))
		}
	}
}

func TestAStoredHashThatIsNotOneMatchesNothing(t *testing.T) {
	for _, stored := range []string{"", rightPassword, "pbkdf2-sha256$0$AAAA$AAAA", "sha1$1000$AAAA$AAAA", "pbkdf2-sha256$1000$!!$AAAA"} {
		if passwordMatches(stored, rightPassword) {
			t.Fatalf("%q let the password in", stored)
		}
	}
}

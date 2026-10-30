package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sync"
)

const (
	maxActivityLimit = 200
	maxLineLength    = 1024
	maxDetailLength  = 120
)

var accountName = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// One line of the activity: who did what, when, and how it ended. Every value
// is one the agent chose or checked; the one exception, the route a refused
// request named, is cut to printable characters and never carries its query.
type Line struct {
	At     string `json:"at"`
	Who    string `json:"who"`
	Action string `json:"action"`
	Result string `json:"result"`
	Detail string `json:"detail,omitempty"`
}

type Activity struct {
	mu   sync.Mutex
	path string
}

func newActivity(path string) *Activity { return &Activity{path: path} }

func (a *Activity) note(line Line) error {
	encoded, err := json.Marshal(line)
	if err != nil {
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := os.MkdirAll(filepath.Dir(a.path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(a.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(append(encoded, '\n')); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// Only the end of the file is read: it grows by a line for every sign-in, and
// is never trimmed.
func (a *Activity) last(n int) ([]Line, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	lines := []Line{}
	file, err := os.Open(a.path)
	if os.IsNotExist(err) {
		return lines, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	start := max(info.Size()-int64(n+1)*maxLineLength, 0)
	tail := make([]byte, info.Size()-start)
	if _, err := file.ReadAt(tail, start); err != nil && err != io.EOF {
		return nil, err
	}
	rows := bytes.Split(bytes.TrimRight(tail, "\n"), []byte("\n"))
	if start > 0 && len(rows) > 0 {
		rows = rows[1:]
	}
	for i := len(rows) - 1; i >= 0 && len(lines) < n; i-- {
		var line Line
		if json.Unmarshal(rows[i], &line) == nil {
			lines = append(lines, line)
		}
	}
	return lines, nil
}

func printable(text string, limit int) string {
	kept := []rune{}
	for _, r := range text {
		if r >= 0x20 && r < 0x7f && len(kept) < limit {
			kept = append(kept, r)
		}
	}
	return string(kept)
}

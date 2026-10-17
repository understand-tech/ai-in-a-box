package main

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	keptLines    = 200
	keptWarnings = 20
)

var (
	imageLanded  = regexp.MustCompile(`^\s+(\d+)/(\d+|\?)\s+\S+\s+\(\d+ min\)$`)
	secretsAreIn = regexp.MustCompile(`The secrets are in (\S+)$`)
)

type Progress struct {
	Running   bool     `json:"running"`
	Finished  bool     `json:"finished"`
	Succeeded bool     `json:"succeeded"`
	Domain    string   `json:"domain"`
	Step      string   `json:"step"`
	Steps     []string `json:"steps"`
	Warnings  []string `json:"warnings"`
	Landed    int      `json:"landed"`
	Total     int      `json:"total"`
	Failure   string   `json:"failure"`
	Lines     []string `json:"lines"`
	Elapsed   int      `json:"elapsed"`
	started   time.Time
	secrets   string
}

func (p Progress) read(line string) Progress {
	p.Lines = append(p.Lines, line)
	if len(p.Lines) > keptLines {
		p.Lines = p.Lines[len(p.Lines)-keptLines:]
	}
	switch {
	case strings.HasPrefix(line, "==> "):
		p.Step = strings.TrimPrefix(line, "==> ")
		p.Steps = append(p.Steps, p.Step)
		p.Landed, p.Total = 0, 0
	case strings.HasPrefix(line, "[warn] "):
		p.Warnings = append(p.Warnings, strings.TrimPrefix(line, "[warn] "))
		if len(p.Warnings) > keptWarnings {
			p.Warnings = p.Warnings[len(p.Warnings)-keptWarnings:]
		}
	case strings.HasPrefix(line, "[fail] "):
		p.Failure = strings.TrimPrefix(line, "[fail] ")
	case imageLanded.MatchString(line):
		match := imageLanded.FindStringSubmatch(line)
		p.Landed, _ = strconv.Atoi(match[1])
		p.Total, _ = strconv.Atoi(match[2])
	case secretsAreIn.MatchString(line):
		p.secrets = secretsAreIn.FindStringSubmatch(line)[1]
	}
	return p
}

func (p Progress) finish(succeeded bool) Progress {
	p.Running, p.Finished, p.Succeeded = false, true, succeeded
	if !succeeded && p.Failure == "" {
		p.Failure = "ut-install stopped — the last lines say why"
	}
	return p
}

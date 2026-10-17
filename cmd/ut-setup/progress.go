package main

import (
	"regexp"
	"strconv"
	"strings"
)

const keptLines = 200

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
	Landed    int      `json:"landed"`
	Total     int      `json:"total"`
	Failure   string   `json:"failure"`
	Lines     []string `json:"lines"`
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
		p.Landed, p.Total = 0, 0
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

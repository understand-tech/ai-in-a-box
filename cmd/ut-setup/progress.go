package main

import "time"

const (
	keptLines    = 200
	keptMessages = 200
)

type Progress struct {
	Running   bool      `json:"running"`
	Finished  bool      `json:"finished"`
	Succeeded bool      `json:"succeeded"`
	Update    bool      `json:"update"`
	Domain    string    `json:"domain"`
	Step      string    `json:"step"`
	Steps     []string  `json:"steps"`
	Messages  []Message `json:"messages"`
	Landed    int       `json:"landed"`
	Total     int       `json:"total"`
	Lines     []string  `json:"lines"`
	Elapsed   int       `json:"elapsed"`
	started   time.Time
	secrets   string
}

func (p Progress) read(line string) Progress {
	p.Lines = append(p.Lines, line)
	if len(p.Lines) > keptLines {
		p.Lines = p.Lines[len(p.Lines)-keptLines:]
	}
	return p
}

func (p Progress) apply(event Event) Progress {
	switch event.Event {
	case "step":
		p.Step = event.Text
		p.Steps = append(p.Steps, event.Text)
		p.Landed, p.Total = 0, 0
	case "image":
		p.Landed, p.Total = event.Landed, 0
		if event.Total != nil {
			p.Total = *event.Total
		}
	case "secrets":
		p.secrets = event.File
	default:
		p.Messages = told(p.Messages, event)
		if len(p.Messages) > keptMessages {
			p.Messages = p.Messages[len(p.Messages)-keptMessages:]
		}
	}
	return p
}

func (p Progress) failed() bool {
	for _, message := range p.Messages {
		if message.Kind == "fail" {
			return true
		}
	}
	return false
}

func (p Progress) finish(succeeded bool) Progress {
	p.Running, p.Finished, p.Succeeded = false, true, succeeded
	if !succeeded && !p.failed() {
		p.Messages = append(p.Messages, Message{Kind: "fail", Text: "ut-install stopped — the last lines say why"})
	}
	return p
}

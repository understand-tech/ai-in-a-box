package main

import (
	"bytes"
	"encoding/json"
	"os"
	"time"
)

const (
	eventsVersion  = 1
	maxEventLength = 1 << 20
	followEvery    = 200 * time.Millisecond
)

type Event struct {
	V              int    `json:"v"`
	Event          string `json:"event"`
	Text           string `json:"text"`
	Landed         int    `json:"landed"`
	Total          *int   `json:"total"`
	Name           string `json:"name"`
	File           string `json:"file"`
	ID             string `json:"id"`
	Served         string `json:"served"`
	Size           string `json:"size"`
	License        string `json:"license"`
	RunsItsOwnCode bool   `json:"runs_its_own_code"`
}

type Message struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

func parseEvent(line []byte) (Event, bool) {
	var event Event
	if json.Unmarshal(line, &event) != nil || event.V != eventsVersion {
		return Event{}, false
	}
	return event, true
}

// ut-install tells a message carried over several lines as its first line,
// then one "more" for each line after it.
func told(messages []Message, event Event) []Message {
	switch event.Event {
	case "ok", "warn", "fail":
		return append(messages, Message{Kind: event.Event, Text: event.Text})
	case "more":
		if len(messages) > 0 && event.Text != "" {
			messages[len(messages)-1].Text += "\n" + event.Text
		}
	}
	return messages
}

// ut-install appends to the file as it goes: it is read as it grows, and once
// more when stop says ut-install has exited.
func follow(path string, stop <-chan struct{}, happened func(Event)) {
	var file *os.File
	var pending []byte
	buffer := make([]byte, 64*1024)
	readWhatIsNew := func() {
		if file == nil {
			opened, err := os.Open(path)
			if err != nil {
				return
			}
			file = opened
		}
		for {
			n, _ := file.Read(buffer)
			if n == 0 {
				return
			}
			pending = append(pending, buffer[:n]...)
			for end := bytes.IndexByte(pending, '\n'); end >= 0; end = bytes.IndexByte(pending, '\n') {
				if event, ok := parseEvent(pending[:end]); ok {
					happened(event)
				}
				pending = pending[end+1:]
			}
			if len(pending) > maxEventLength {
				pending = nil
			}
		}
	}
	for {
		select {
		case <-stop:
			readWhatIsNew()
			if file != nil {
				file.Close()
			}
			return
		case <-time.After(followEvery):
			readWhatIsNew()
		}
	}
}

package main

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"
)

const (
	usageSeries     = `{__name__=~"vllm:.*|ut_inference_.*|ut_cost_.*|caddy_.*"}`
	hourMillis      = int64(time.Hour / time.Millisecond)
	dayMillis       = 24 * hourMillis
	recorderKeeps   = 35 * dayMillis
	recorderService = "metrics"
)

var namedSurfaces = map[string]bool{"llms": true, "admin": true, "assistants": true, "builder": true}

// The client's domain never leaves the box: each host Caddy counted becomes the
// surface it names, and anything else becomes "_other".
func surface(host, domain string) string {
	if domain == "" || host == "" {
		return "_other"
	}
	if host == domain {
		return "app"
	}
	name, found := strings.CutSuffix(host, "."+domain)
	if !found || name == "" {
		return "_other"
	}
	if strings.HasSuffix(name, ".apps") {
		return "apps"
	}
	if namedSurfaces[name] {
		return name
	}
	return "_other"
}

var hostLabel = regexp.MustCompile(`host="([^"]*)"`)

func rewriteSurfaces(dump, domain string) string {
	lines := strings.SplitAfter(dump, "\n")
	for i, line := range lines {
		if !strings.HasPrefix(line, "caddy_") {
			continue
		}
		lines[i] = hostLabel.ReplaceAllStringFunc(line, func(label string) string {
			return `host="` + surface(hostLabel.FindStringSubmatch(label)[1], domain) + `"`
		})
	}
	return strings.Join(lines, "")
}

type window struct{ from, to int64 }

// Resumes an hour before the last export, so a sample written late is not
// lost; a first export takes what the recorder still keeps.
func usageWindows(lastExported int64, now time.Time) []window {
	end := now.UnixMilli()
	start := end - recorderKeeps
	if lastExported > 0 {
		start = lastExported - hourMillis
	}
	var windows []window
	for from := start; from < end; {
		to := min(from+dayMillis, end)
		windows = append(windows, window{from, to})
		from = to
	}
	return windows
}

// No name and no time in the header: the same samples give the same bytes.
func gzipped(text string) []byte {
	var buffer bytes.Buffer
	writer := gzip.NewWriter(&buffer)
	io.WriteString(writer, text)
	writer.Close()
	return buffer.Bytes()
}

func holdsSamples(dump string) bool {
	return strings.TrimSpace(dump) != "" && !strings.HasPrefix(dump, "# EOF")
}

func (m machine) dumpUsage(recorder string, w window) (string, error) {
	return m.run("", "docker", "exec", recorder, "promtool", "tsdb", "dump-openmetrics",
		fmt.Sprintf("--min-time=%d", w.from), fmt.Sprintf("--max-time=%d", w.to),
		"--match="+usageSeries, "/prometheus")
}

func (m machine) domain(rows []container) string {
	caddy := runningContainer(rows, "caddy")
	if caddy == "" {
		return ""
	}
	domain, err := m.run("", "docker", "exec", caddy, "printenv", "UT_DOMAIN")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(domain)
}

var errNoRecorder = errors.New("no recorder runs here; nothing to export")

// The mark moves only once a window is in line: a failure leaves it for the
// next pass, and an empty window is passed over.
func collectUsage(place Place, m machine) error {
	unlock, err := lockState(place.State)
	if err != nil {
		return err
	}
	defer unlock()
	rows := m.containers()
	recorder := runningContainer(rows, recorderService)
	if recorder == "" {
		return errNoRecorder
	}
	domain := m.domain(rows)
	state, err := loadState(place.State)
	if err != nil {
		return err
	}
	for _, w := range usageWindows(state.LastExported, place.Now()) {
		dump, err := m.dumpUsage(recorder, w)
		if err != nil {
			return fmt.Errorf("the recorder could not be read: %w", err)
		}
		if holdsSamples(dump) {
			if err := enqueue(queueDir(place.State), "usage", gzipped(rewriteSurfaces(dump, domain)), place.Now()); err != nil {
				return err
			}
		}
		state.LastExported = w.to
		if err := saveState(place.State, state); err != nil {
			return err
		}
	}
	return nil
}

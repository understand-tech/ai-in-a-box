package main

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"sort"
	"strconv"
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

var usageLine = regexp.MustCompile(`^([A-Za-z_:][A-Za-z0-9_:]*)(\{.*\})?[ \t]+([^ \t]+)[ \t]+([^ \t]+)$`)
var usageNumber = regexp.MustCompile(`^(?:[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|NaN|[+-]?Inf)$`)
var usageLabel = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\\r\n]|\\[\\n"])*)"(,|$)`)

var additiveCaddySeries = map[string]bool{
	"caddy_http_requests_total":                  true,
	"caddy_http_request_errors_total":            true,
	"caddy_http_request_duration_seconds_bucket": true,
	"caddy_http_request_duration_seconds_sum":    true,
	"caddy_http_request_duration_seconds_count":  true,
}

type usageSample struct {
	series, sourceHost, timeText, valueText string
	timestamp                               int64
	value                                   float64
	additive                                bool
}

func parseUsageSample(line, domain string) (usageSample, error) {
	parts := usageLine.FindStringSubmatch(line)
	if parts == nil || !usageNumber.MatchString(parts[3]) || !usageNumber.MatchString(parts[4]) {
		return usageSample{}, errors.New("unsupported scalar sample")
	}
	value, err := strconv.ParseFloat(parts[3], 64)
	if err != nil {
		return usageSample{}, errors.New("invalid sample value")
	}
	seconds, err := strconv.ParseFloat(parts[4], 64)
	millis := seconds * 1000
	if err != nil || math.IsNaN(millis) || math.IsInf(millis, 0) || millis < float64(math.MinInt64) || millis >= -float64(math.MinInt64) {
		return usageSample{}, errors.New("invalid sample timestamp")
	}
	sample := usageSample{series: parts[1], timeText: parts[4], valueText: parts[3], value: value, timestamp: int64(millis)}
	body := strings.TrimSuffix(strings.TrimPrefix(parts[2], "{"), "}")
	labels := map[string]string{}
	for body != "" {
		label := usageLabel.FindStringSubmatch(body)
		if label == nil || label[1] == "__name__" {
			return usageSample{}, errors.New("unsupported sample labels")
		}
		if _, exists := labels[label[1]]; exists {
			return usageSample{}, errors.New("duplicate sample label")
		}
		labels[label[1]] = label[2]
		if label[1] == "host" && strings.HasPrefix(parts[1], "caddy_") {
			host, err := strconv.Unquote(`"` + label[2] + `"`)
			if err != nil {
				return usageSample{}, errors.New("invalid host label")
			}
			sample.sourceHost = host
			labels["host"] = surface(host, domain)
			sample.additive = additiveCaddySeries[parts[1]] && (labels["host"] == "apps" || labels["host"] == "_other")
		}
		body = body[len(label[0]):]
		if body == "" && label[3] == "," {
			return usageSample{}, errors.New("trailing label separator")
		}
	}
	if len(labels) > 0 {
		names := make([]string, 0, len(labels))
		for name := range labels {
			names = append(names, name)
		}
		sort.Strings(names)
		encoded := make([]string, 0, len(names))
		for _, name := range names {
			encoded = append(encoded, name+`="`+labels[name]+`"`)
		}
		sample.series += "{" + strings.Join(encoded, ",") + "}"
	}
	return sample, nil
}

func sameUsageValue(left, right float64) bool {
	return left == right || math.IsNaN(left) && math.IsNaN(right)
}

func rewriteSurfaces(dump, domain string) (string, error) {
	var samples []usageSample
	ended := false
	for number, line := range strings.Split(dump, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if ended {
			return "", errors.New("data after OpenMetrics EOF")
		}
		if line == "# EOF" {
			ended = true
			continue
		}
		sample, err := parseUsageSample(line, domain)
		if err != nil {
			return "", fmt.Errorf("usage line %d: %w", number+1, err)
		}
		samples = append(samples, sample)
	}
	if !ended {
		return "", errors.New("missing OpenMetrics EOF")
	}
	sort.SliceStable(samples, func(i, j int) bool {
		if samples[i].series != samples[j].series {
			return samples[i].series < samples[j].series
		}
		return samples[i].timestamp < samples[j].timestamp
	})
	var output strings.Builder
	for i := 0; i < len(samples); {
		first := samples[i]
		values := map[string]float64{first.sourceHost: first.value}
		sum := first.value
		j := i + 1
		for j < len(samples) && samples[j].series == first.series && samples[j].timestamp == first.timestamp {
			next := samples[j]
			if previous, exists := values[next.sourceHost]; exists {
				if !sameUsageValue(previous, next.value) {
					return "", errors.New("conflicting samples from one source")
				}
			} else {
				if !first.additive && !sameUsageValue(first.value, next.value) {
					return "", errors.New("conflicting non-additive samples")
				}
				values[next.sourceHost] = next.value
				sum += next.value
			}
			j++
		}
		value := first.valueText
		if first.additive && len(values) > 1 {
			value = strconv.FormatFloat(sum, 'g', -1, 64)
		}
		fmt.Fprintf(&output, "%s %s %s\n", first.series, value, first.timeText)
		i = j
	}
	output.WriteString("# EOF\n")
	return output.String(), nil
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
		normalized, err := rewriteSurfaces(dump, domain)
		if err != nil {
			return fmt.Errorf("the recorder export could not be normalized: %w", err)
		}
		if holdsSamples(normalized) {
			if err := enqueue(queueDir(place.State), "usage", gzipped(normalized), place.Now()); err != nil {
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

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

const reportSchema = 3

// ut-report writes the base report; health and tools are added to it here, and
// the warnings of all three are kept together, each named once.
func enrich(base []byte, health Health, tools Tools, warnings []string) ([]byte, error) {
	var report map[string]json.RawMessage
	if err := json.Unmarshal(base, &report); err != nil {
		return nil, fmt.Errorf("ut-report wrote something that is not a report: %w", err)
	}
	var existing []string
	if raw, ok := report["warnings"]; ok {
		if err := json.Unmarshal(raw, &existing); err != nil {
			return nil, fmt.Errorf("the report's warnings cannot be read: %w", err)
		}
	}
	seen := map[string]bool{}
	merged := []string{}
	for _, warning := range append(existing, warnings...) {
		if !seen[warning] {
			seen[warning] = true
			merged = append(merged, warning)
		}
	}
	sort.Strings(merged)
	for key, value := range map[string]any{"schema": reportSchema, "health": health, "tools": tools, "warnings": merged} {
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		report[key] = encoded
	}
	return json.MarshalIndent(report, "", "  ")
}

func windowDays(base []byte) int {
	var report struct {
		WindowDays int `json:"window_days"`
	}
	if json.Unmarshal(base, &report) != nil || report.WindowDays <= 0 {
		return 30
	}
	return report.WindowDays
}

func baseReport(run Runner, workDir string) ([]byte, error) {
	if _, err := run("", "ut-report", "--out", workDir); err != nil {
		return nil, fmt.Errorf("ut-report failed: %w", err)
	}
	written, err := filepath.Glob(filepath.Join(workDir, "ut-report-*", "report.json"))
	if err != nil || len(written) != 1 {
		return nil, errors.New("ut-report did not write exactly one report")
	}
	return os.ReadFile(written[0])
}

func collectReport(m machine, workDir string) ([]byte, error) {
	base, err := baseReport(m.run, workDir)
	if err != nil {
		return nil, err
	}
	health, healthWarnings := m.health()
	tools, toolsWarnings := m.tools(windowDays(base))
	return enrich(base, health, tools, append(healthWarnings, toolsWarnings...))
}

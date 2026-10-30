package main

import (
	"encoding/json"
	"strings"
	"syscall"
	"time"
)

const machineFile = "/etc/understandtech/machine.lic"

var healthWorstFirst = []string{"unhealthy", "starting", "", "healthy"}

type Service struct {
	Name     string `json:"name"`
	State    string `json:"state"`
	Health   string `json:"health"`
	Replicas int    `json:"replicas"`
	Running  int    `json:"running"`
}

type Disk struct {
	Path           string `json:"path"`
	TotalBytes     int64  `json:"total_bytes"`
	AvailableBytes int64  `json:"available_bytes"`
}

type Status struct {
	Release      string    `json:"release"`
	Domain       string    `json:"domain"`
	Model        string    `json:"model"`
	Services     []Service `json:"services"`
	LastBackup   string    `json:"last_backup"`
	Disks        []Disk    `json:"disks"`
	LicenseUntil string    `json:"license_until"`
	Reporting    string    `json:"reporting"`
}

type container struct {
	Service string `json:"Service"`
	State   string `json:"State"`
	Health  string `json:"Health"`
}

// Compose prints one object a line since 2.21, an array before.
func parseContainers(output string) []container {
	var found []container
	trimmed := strings.TrimSpace(output)
	if strings.HasPrefix(trimmed, "[") {
		json.Unmarshal([]byte(trimmed), &found)
		return found
	}
	for _, line := range strings.Split(trimmed, "\n") {
		var one container
		if json.Unmarshal([]byte(line), &one) == nil && one.Service != "" {
			found = append(found, one)
		}
	}
	return found
}

func worseHealth(a, b string) string {
	rank := func(health string) int {
		for i, known := range healthWorstFirst {
			if known == health {
				return i
			}
		}
		return 0
	}
	if rank(b) < rank(a) {
		return b
	}
	return a
}

func servicesOf(declared []string, containers []container) []Service {
	found := []Service{}
	for _, name := range declared {
		service := Service{Name: name, State: "not created", Health: "healthy"}
		for _, one := range containers {
			if one.Service != name {
				continue
			}
			service.Replicas++
			if one.State == "running" {
				service.Running++
			} else {
				service.State = one.State
			}
			service.Health = worseHealth(service.Health, one.Health)
		}
		if service.Replicas == 0 {
			service.Health = ""
		} else if service.Running == service.Replicas {
			service.State = "running"
		}
		found = append(found, service)
	}
	return found
}

type spaceReader func(path string) (device uint64, total, available int64, ok bool)

func statfsReader(path string) (uint64, int64, int64, bool) {
	var stat syscall.Stat_t
	var fs syscall.Statfs_t
	if syscall.Stat(path, &stat) != nil || syscall.Statfs(path, &fs) != nil {
		return 0, 0, 0, false
	}
	return uint64(stat.Dev), int64(fs.Blocks) * int64(fs.Frsize), int64(fs.Bavail) * int64(fs.Frsize), true
}

// One line per filesystem: two paths on the same disk are one disk.
func disks(paths []string, read spaceReader) []Disk {
	found := []Disk{}
	seen := map[uint64]bool{}
	for _, path := range paths {
		device, total, available, ok := read(path)
		if !ok || seen[device] {
			continue
		}
		seen[device] = true
		found = append(found, Disk{path, total, available})
	}
	return found
}

func latestSnapshot(output string) string {
	var snapshots []struct {
		Time time.Time `json:"time"`
	}
	if json.Unmarshal([]byte(output), &snapshots) != nil {
		return ""
	}
	var latest time.Time
	for _, snapshot := range snapshots {
		if snapshot.Time.After(latest) {
			latest = snapshot.Time
		}
	}
	if latest.IsZero() {
		return ""
	}
	return latest.UTC().Format(time.RFC3339)
}

func firstLine(text string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(text), "\n")
	return printable(line, 200)
}

func (a *Agent) answer(name string, args ...string) string {
	output, err := a.run(a.box.Install, name, args...)
	if err != nil {
		return ""
	}
	return output
}

func (a *Agent) collect() Status {
	declared, _ := a.services()
	containers := parseContainers(a.answer("docker", "compose", "ps", "--all", "--format", "json"))
	status := Status{
		Release:   a.box.setting("UT_RELEASE_VERSION"),
		Domain:    a.box.setting("UT_DOMAIN"),
		Model:     a.box.setting("UT_MODEL"),
		Services:  servicesOf(declared, containers),
		Disks:     disks([]string{"/", a.box.dataRoot()}, a.space),
		Reporting: firstLine(a.answer("ut-send", "status")),
	}
	for _, service := range status.Services {
		if service.Name == "files-backup" && service.Running > 0 {
			status.LastBackup = latestSnapshot(a.answer("docker", "compose", "exec", "-T", "files-backup", "restic", "snapshots", "--tag", "files", "--latest", "1", "--json"))
		}
	}
	if fileExists(machineFile) {
		status.LicenseUntil = firstLine(a.answer("ut-license", "field", "expires", machineFile))
	}
	return status
}

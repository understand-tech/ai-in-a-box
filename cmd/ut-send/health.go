package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	commandTimeout = 30 * time.Second
	enginePort     = 8000
	dataRoot       = "/var/lib/understandtech"
	inspectFormat  = `{{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} ` +
		`{{with index .State "Health"}}{{.Status}}{{else}}none{{end}} ` +
		`{{.RestartCount}} {{.State.OOMKilled}} {{.Id}}`
)

var worstFirst = []string{"unhealthy", "starting", "none", "healthy"}

const caddyAuthorityRoot = "/data/caddy/pki/authorities/local/root.crt"

// Runner runs a command in a directory and returns what it printed, or an
// error when it failed or ran out of time.
type Runner func(dir, name string, args ...string) (string, error)

func systemRunner(dir, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	output, err := command.Output()
	return string(output), err
}

type Service struct {
	Service   string `json:"service"`
	Replicas  int    `json:"replicas"`
	Running   int    `json:"running"`
	Health    string `json:"health"`
	Restarts  int    `json:"restarts"`
	OOMKilled bool   `json:"oom_killed"`
}

type Queue struct {
	Queue   string `json:"queue"`
	Waiting int    `json:"waiting"`
	Failed  int    `json:"failed"`
}

type Disk struct {
	Path           string `json:"path"`
	TotalBytes     *int64 `json:"total_bytes"`
	AvailableBytes *int64 `json:"available_bytes"`
}

type Engine struct {
	Service        string   `json:"service"`
	ServedModels   []string `json:"served_models"`
	DeclaredModel  *string  `json:"declared_model"`
	Requests       *int64   `json:"requests"`
	GPUMemoryBytes *int64   `json:"gpu_memory_bytes"`
	CachedModel    *string  `json:"cached_model"`
	ModelPath      *string  `json:"model_path"`
}

type Backup struct {
	Kind   string  `json:"kind"`
	LastAt *string `json:"last_at"`
}

type Certificate struct {
	Name      string  `json:"name"`
	NotBefore *string `json:"not_before"`
	NotAfter  *string `json:"not_after"`
}

type Health struct {
	Services        []Service     `json:"services"`
	Queues          []Queue       `json:"queues"`
	Workers         *int          `json:"workers"`
	Disks           []Disk        `json:"disks"`
	Engines         []Engine      `json:"engines"`
	Backups         []Backup      `json:"backups"`
	Certificates    []Certificate `json:"certificates"`
	NTPSynchronized *bool         `json:"ntp_synchronized"`
}

type container struct {
	service, status, health string
	restarts                int
	oomKilled               bool
	id                      string
}

func utc(moment time.Time) string { return moment.UTC().Format("2006-01-02T15:04:05Z") }

func optional[T any](value T) *T { return &value }

func parseContainers(inspected string) []container {
	var rows []container
	for _, line := range strings.Split(inspected, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 6 {
			continue
		}
		restarts, err := strconv.Atoi(fields[3])
		if err != nil {
			continue
		}
		health := fields[2]
		if !known(health) {
			health = "none"
		}
		rows = append(rows, container{fields[0], fields[1], health, restarts, fields[4] == "true", fields[5]})
	}
	return rows
}

func runningContainer(rows []container, service string) string {
	for _, row := range rows {
		if row.service == service && row.status == "running" {
			return row.id
		}
	}
	return ""
}

func known(health string) bool {
	for _, state := range worstFirst {
		if state == health {
			return true
		}
	}
	return false
}

func worse(a, b string) string {
	rank := func(state string) int {
		for i, known := range worstFirst {
			if known == state {
				return i
			}
		}
		return 2
	}
	if rank(b) < rank(a) {
		return b
	}
	return a
}

func services(rows []container) []Service {
	byName := map[string]*Service{}
	for _, row := range rows {
		entry, seen := byName[row.service]
		if !seen {
			entry = &Service{Service: row.service, Health: "healthy"}
			byName[row.service] = entry
		}
		entry.Replicas++
		if row.status == "running" {
			entry.Running++
		}
		entry.Health = worse(entry.Health, row.health)
		entry.Restarts += row.restarts
		entry.OOMKilled = entry.OOMKilled || row.oomKilled
	}
	found := []Service{}
	for _, entry := range byName {
		found = append(found, *entry)
	}
	sort.Slice(found, func(i, j int) bool { return found[i].Service < found[j].Service })
	return found
}

func redis(run Runner, id string, args ...string) (string, bool) {
	output, err := run("", "docker", append([]string{"exec", id, "redis-cli"}, args...)...)
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(output), true
}

func queues(run Runner, id string) []Queue {
	found := []Queue{}
	keys, _ := redis(run, id, "SMEMBERS", "rq:queues")
	names := strings.Fields(keys)
	sort.Strings(names)
	for _, key := range names {
		name := strings.TrimPrefix(key, "rq:queue:")
		waiting, _ := redis(run, id, "LLEN", key)
		failed, _ := redis(run, id, "ZCARD", "rq:failed:"+name)
		w, _ := strconv.Atoi(waiting)
		f, _ := strconv.Atoi(failed)
		found = append(found, Queue{name, w, f})
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

// One line per filesystem: three paths on the same disk are one disk.
func disks(paths []string, read spaceReader) []Disk {
	found := []Disk{}
	seen := map[uint64]bool{}
	for _, path := range paths {
		if path == "" {
			continue
		}
		device, total, available, ok := read(path)
		if !ok || seen[device] {
			continue
		}
		seen[device] = true
		found = append(found, Disk{path, optional(total), optional(available)})
	}
	return found
}

func metricSum(text, name string) *int64 {
	var sum float64
	found := false
	for _, line := range strings.Split(text, "\n") {
		if !strings.HasPrefix(line, name+"{") && !strings.HasPrefix(line, name+" ") {
			continue
		}
		fields := strings.Fields(line)
		value, err := strconv.ParseFloat(fields[len(fields)-1], 64)
		if err != nil {
			continue
		}
		sum += value
		found = true
	}
	if !found {
		return nil
	}
	return optional(int64(sum + 0.5))
}

var containerInCgroup = regexp.MustCompile(`[0-9a-f]{64}`)

func containerOfProcess(pid string) string {
	content, err := os.ReadFile("/proc/" + pid + "/cgroup")
	if err != nil {
		return ""
	}
	return containerInCgroup.FindString(string(content))
}

func gpuMemory(csv string, ownerOf func(pid string) string) map[string]int64 {
	held := map[string]int64{}
	for _, line := range strings.Split(csv, "\n") {
		pid, mebibytes, found := strings.Cut(line, ",")
		if !found {
			continue
		}
		owner := ownerOf(strings.TrimSpace(pid))
		amount, err := strconv.ParseInt(strings.TrimSpace(mebibytes), 10, 64)
		if owner == "" || err != nil {
			continue
		}
		held[owner] += amount * 1024 * 1024
	}
	return held
}

func loadedWeights(output string) (model, path *string) {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "":
		case strings.HasPrefix(line, "model:"):
			if value := strings.TrimSpace(strings.TrimPrefix(line, "model:")); value != "" && model == nil {
				model = optional(value)
			}
		case path == nil:
			path = optional(line)
		}
	}
	return model, path
}

func servedModels(run Runner, id string) []string {
	output, err := run("", "docker", "exec", id, "curl", "-sf", "--max-time", "5", fmt.Sprintf("http://127.0.0.1:%d/v1/models", enginePort))
	var answer struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	models := []string{}
	if err != nil || json.Unmarshal([]byte(output), &answer) != nil {
		return models
	}
	for _, model := range answer.Data {
		models = append(models, model.ID)
	}
	sort.Strings(models)
	return models
}

func environment(run Runner, id, name string) *string {
	value, err := run("", "docker", "exec", id, "printenv", name)
	if err != nil || strings.TrimSpace(value) == "" {
		return nil
	}
	return optional(strings.TrimSpace(value))
}

func engines(run Runner, rows []container, held map[string]int64, warnings *[]string) []Engine {
	found := []Engine{}
	var names []string
	seen := map[string]bool{}
	for _, row := range rows {
		if strings.HasPrefix(row.service, "nim-") && !seen[row.service] {
			seen[row.service] = true
			names = append(names, row.service)
		}
	}
	sort.Strings(names)
	for _, service := range names {
		id := runningContainer(rows, service)
		if id == "" {
			continue
		}
		models := servedModels(run, id)
		if len(models) == 0 {
			*warnings = append(*warnings, "health-unreadable:engine:"+service)
		}
		engine := Engine{Service: service, ServedModels: models}
		if metrics, err := run("", "docker", "exec", id, "curl", "-sf", "--max-time", "5", fmt.Sprintf("http://127.0.0.1:%d/metrics", enginePort)); err == nil {
			engine.Requests = metricSum(metrics, "vllm:request_success_total")
		}
		if amount, ok := held[id]; ok {
			engine.GPUMemoryBytes = optional(amount)
		}
		// compose.engine-vllm.yaml keeps the NIM settings of the service it
		// replaces: on a vLLM engine they name a model that does not run.
		if model := environment(run, id, "VLLM_ENGINE_MODEL"); model != nil {
			engine.DeclaredModel = model
		} else {
			engine.DeclaredModel = environment(run, id, "NIM_SERVED_MODEL_NAME")
			weights, _ := run("", "docker", "exec", id, "sh", "-c",
				`grep -m1 "^model:" "$NIM_CACHE_PATH/nim_runtime_manifest.yaml"; printenv NIM_MODEL_PATH`)
			engine.CachedModel, engine.ModelPath = loadedWeights(weights)
		}
		found = append(found, engine)
	}
	return found
}

func lastMongoBackup(run Runner, id string) *string {
	output, err := run("", "docker", "exec", id, "sh", "-c", "ls -t /backup/mongo_*.archive.gz 2>/dev/null | head -1 | xargs -r stat -c %Y")
	seconds, parseErr := strconv.ParseInt(strings.TrimSpace(output), 10, 64)
	if err != nil || parseErr != nil {
		return nil
	}
	return optional(utc(time.Unix(seconds, 0)))
}

func lastFilesBackup(run Runner, id string) *string {
	output, err := run("", "docker", "exec", id, "restic", "snapshots", "--tag", "files", "--latest", "1", "--json")
	var snapshots []struct {
		Time time.Time `json:"time"`
	}
	if err != nil || json.Unmarshal([]byte(output), &snapshots) != nil || len(snapshots) == 0 {
		return nil
	}
	latest := snapshots[0].Time
	for _, snapshot := range snapshots[1:] {
		if snapshot.Time.After(latest) {
			latest = snapshot.Time
		}
	}
	return optional(utc(latest))
}

func backups(run Runner, rows []container, warnings *[]string) []Backup {
	found := []Backup{}
	readers := []struct {
		kind, service string
		read          func(Runner, string) *string
	}{
		{"mongodb", "mongodb-backup", lastMongoBackup},
		{"files", "files-backup", lastFilesBackup},
	}
	for _, reader := range readers {
		id := runningContainer(rows, reader.service)
		if id == "" {
			continue
		}
		last := reader.read(run, id)
		if last == nil {
			*warnings = append(*warnings, "health-unreadable:backup:"+reader.kind)
		}
		found = append(found, Backup{reader.kind, last})
	}
	return found
}

func validity(name string, certificate *x509.Certificate) Certificate {
	if certificate == nil {
		return Certificate{Name: name}
	}
	return Certificate{name, optional(utc(certificate.NotBefore)), optional(utc(certificate.NotAfter))}
}

func parsePEM(content string) *x509.Certificate {
	block, _ := pem.Decode([]byte(content))
	if block == nil {
		return nil
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil
	}
	return certificate
}

// Only its dates are read: whether a browser would trust it is not the question.
func ingressCertificate(domain string) *x509.Certificate {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	connection, err := tls.DialWithDialer(dialer, "tcp", "127.0.0.1:443", &tls.Config{ServerName: domain, InsecureSkipVerify: true})
	if err != nil {
		return nil
	}
	defer connection.Close()
	chain := connection.ConnectionState().PeerCertificates
	if len(chain) == 0 {
		return nil
	}
	return chain[0]
}

// A compute node's Caddy serves inference under its own root, never the
// platform's address: it has no api container, running or not.
func servesThePlatform(rows []container) bool {
	for _, row := range rows {
		if row.service == "api" {
			return true
		}
	}
	return false
}

func certificates(run Runner, rows []container, ingress func(domain string) *x509.Certificate, warnings *[]string) []Certificate {
	found := []Certificate{}
	caddy := runningContainer(rows, "caddy")
	if caddy == "" {
		return found
	}
	if servesThePlatform(rows) {
		var certificate *x509.Certificate
		if domain, err := run("", "docker", "exec", caddy, "printenv", "UT_DOMAIN"); err == nil && strings.TrimSpace(domain) != "" {
			certificate = ingress(strings.TrimSpace(domain))
		}
		found = append(found, validity("ingress", certificate))
	}
	root, _ := run("", "docker", "exec", caddy, "cat", caddyAuthorityRoot)
	found = append(found, validity("ca-root", parsePEM(root)))
	for _, certificate := range found {
		if certificate.NotAfter == nil {
			*warnings = append(*warnings, "health-unreadable:certificate:"+certificate.Name)
		}
	}
	return found
}

func ntpSynchronized(run Runner) *bool {
	answer, _ := run("", "timedatectl", "show", "-p", "NTPSynchronized", "--value")
	switch strings.TrimSpace(answer) {
	case "yes":
		return optional(true)
	case "no":
		return optional(false)
	}
	return nil
}

type machine struct {
	run        Runner
	installDir string
	space      spaceReader
	ownerOf    func(pid string) string
	ingress    func(domain string) *x509.Certificate
}

// Found by Compose's own project label: compose itself would need the settings
// file, which only root reads.
func (m machine) containers() []container {
	project := "label=com.docker.compose.project=" + filepath.Base(m.installDir)
	ids, err := m.run("", "docker", "ps", "-aq", "--filter", project)
	if err != nil || strings.TrimSpace(ids) == "" {
		return nil
	}
	inspected, err := m.run("", "docker", append([]string{"inspect", "-f", inspectFormat}, strings.Fields(ids)...)...)
	if err != nil {
		return nil
	}
	return parseContainers(inspected)
}

func (m machine) health() (Health, []string) {
	warnings := []string{}
	rows := m.containers()
	section := Health{Services: services(rows), Queues: []Queue{}}
	if id := runningContainer(rows, "redis"); id != "" {
		section.Queues = queues(m.run, id)
		if workers, ok := redis(m.run, id, "SCARD", "rq:workers"); ok {
			if n, err := strconv.Atoi(workers); err == nil {
				section.Workers = optional(n)
			}
		}
	}
	dockerRoot, _ := m.run("", "docker", "info", "-f", "{{.DockerRootDir}}")
	section.Disks = disks([]string{"/", strings.TrimSpace(dockerRoot), dataRoot}, m.space)
	held, _ := m.run("", "nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits")
	section.Engines = engines(m.run, rows, gpuMemory(held, m.ownerOf), &warnings)
	section.Backups = backups(m.run, rows, &warnings)
	section.Certificates = certificates(m.run, rows, m.ingress, &warnings)
	section.NTPSynchronized = ntpSynchronized(m.run)
	return section, warnings
}

package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultInstall    = "/usr/share/understandtech"
	defaultSocket     = "/run/ut-agent/agent.sock"
	defaultGroup      = "ut-console"
	defaultConsoleDir = "/var/lib/understandtech/console"
	defaultDataRoot   = "/var/lib/understandtech"
	socketMode        = 0o660
	commandTimeout    = 30 * time.Second
	maxCommandOutput  = 2 << 20
)

// Runner runs a command in a directory and returns what it printed, or an
// error when it failed or ran out of time. Never a shell: name and arguments
// reach the program as they are.
type Runner func(dir, name string, args ...string) (string, error)

func systemRunner(dir, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	output := &boundedBuffer{limit: maxCommandOutput}
	command.Stdout = output
	err := command.Run()
	return output.String(), err
}

// What a command prints past the limit is read and dropped, so the command is
// never left blocked on a pipe nobody reads.
type boundedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if room := b.limit - b.Len(); room > 0 {
		b.Buffer.Write(p[:min(room, len(p))])
	}
	return len(p), nil
}

// Read as ut-install's env_get reads it: the first assignment, one layer of
// quotes taken off.
func settingValue(settings, key string) string {
	scanner := bufio.NewScanner(strings.NewReader(settings))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimLeft(scanner.Text(), " \t")
		value, found := strings.CutPrefix(line, key+"=")
		if !found {
			continue
		}
		value = strings.TrimSuffix(strings.TrimPrefix(value, `"`), `"`)
		return strings.TrimSuffix(strings.TrimPrefix(value, "'"), "'")
	}
	return ""
}

// Read again on every question: ut-install rewrites .env on each run, and the
// agent keeps running across them.
type Box struct {
	Install string
}

func (b Box) setting(key string) string {
	settings, err := os.ReadFile(filepath.Join(b.Install, ".env"))
	if err != nil {
		return ""
	}
	return settingValue(string(settings), key)
}

func (b Box) settingOr(key, fallback string) string {
	if value := b.setting(key); value != "" {
		return value
	}
	return fallback
}

func (b Box) dataRoot() string { return b.settingOr("DATA_ROOT", defaultDataRoot) }

// The umask is the whole process's: set before the socket exists, it keeps the
// socket closed to all but root until its group and mode are given.
func listenOn(path string, gid int) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	previous := syscall.Umask(0o177)
	listener, err := net.Listen("unix", path)
	syscall.Umask(previous)
	if err != nil {
		return nil, err
	}
	if err := os.Chown(path, os.Getuid(), gid); err != nil {
		listener.Close()
		return nil, err
	}
	if err := os.Chmod(path, socketMode); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

func groupID(name string) (int, error) {
	group, err := user.LookupGroup(name)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(group.Gid)
}

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(args []string, stderr io.Writer) int {
	flags := flag.NewFlagSet("ut-agent", flag.ContinueOnError)
	flags.SetOutput(stderr)
	install := flags.String("dir", defaultInstall, "the install directory, where .env is")
	socket := flags.String("socket", defaultSocket, "the socket the console asks on")
	groupName := flags.String("group", defaultGroup, "the group that alone may open the socket")
	consoleDir := flags.String("console-dir", defaultConsoleDir, "where the console's certificate is written")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	logger := log.New(stderr, "ut-agent: ", 0)

	gid, err := groupID(*groupName)
	if err != nil {
		logger.Printf("no group %s, which alone may open the socket: %v", *groupName, err)
		return 1
	}
	box := Box{Install: *install}
	listener, err := listenOn(*socket, gid)
	if err != nil {
		logger.Printf("cannot listen on %s: %v", *socket, err)
		return 1
	}
	agent := newAgent(box, systemRunner, newActivity(filepath.Join(box.dataRoot(), "activity", "activity.jsonl")), time.Now)
	go keepTheCertificateCurrent(Certifier{Box: box, Dir: *consoleDir, Group: gid, Run: systemRunner, Now: time.Now}, logger)

	server := &http.Server{Handler: agent, ReadHeaderTimeout: 10 * time.Second, WriteTimeout: 2 * commandTimeout}
	fmt.Fprintf(stderr, "ut-agent: answering on %s, for the group %s\n", *socket, *groupName)
	if err := server.Serve(listener); err != nil {
		logger.Print(err)
		return 1
	}
	return 0
}

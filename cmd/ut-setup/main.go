package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
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

const codeAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// ut-get --from passes on what it found in the folder it was given.
func parseSetup(args []string, stderr io.Writer) (string, Folder, error) {
	flags := flag.NewFlagSet("ut-setup", flag.ContinueOnError)
	flags.SetOutput(stderr)
	installer := flags.String("install", "ut-install", "the installer to run")
	images := flags.String("images-from", "", "the folder the images come from")
	license := flags.String("machine-file", "", "the license file the folder carries")
	err := flags.Parse(args)
	return *installer, Folder{Images: *images, License: *license}, err
}

func run(args []string, stdout, stderr io.Writer) int {
	installer, folder, err := parseSetup(args, stderr)
	if err != nil {
		return 2
	}

	listener, err := listen()
	if err != nil {
		fmt.Fprintln(stderr, "ut-setup: cannot listen on this machine:", err)
		return 1
	}
	port := listener.Addr().(*net.TCPAddr).Port
	code, session := randomCode(20), randomHex(32)
	wizard := newWizard(runInstaller(installer), folder, code, session,
		fmt.Sprintf("127.0.0.1:%d", port), fmt.Sprintf("localhost:%d", port))
	wizard.pairer = runPair("ut-pair")

	server := &http.Server{Handler: wizard.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)

	address := fmt.Sprintf("http://127.0.0.1:%d/?code=%s", port, code)
	fmt.Fprintf(stdout, "Open this address in a browser on this machine:\n\n  %s\n\n", address)
	openTheDesktopBrowser(address)
	fmt.Fprintln(stdout, "It works once, for one browser. The install can also run without it: sudo ut-install")

	reason := <-wizard.Stopped()
	time.Sleep(time.Second)
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server.Shutdown(shutdown)
	fmt.Fprintln(stdout, "ut-setup:", reason)
	return 0
}

// Setsid leaves ut-install without a terminal: it then prints no secret on
// /dev/tty and says which file holds them, which is what the wizard reads.
func runInstaller(path string) Installer {
	return func(ctx context.Context, args []string, said func(string), happened func(Event)) error {
		folder, err := os.MkdirTemp("", "ut-setup-events-*")
		if err != nil {
			return fmt.Errorf("cannot keep what %s tells: %w", path, err)
		}
		defer os.RemoveAll(folder)
		events := filepath.Join(folder, "events.jsonl")

		command := exec.CommandContext(ctx, path, append([]string{"--events", events}, args...)...)
		command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		reader, writer := io.Pipe()
		command.Stdout, command.Stderr = writer, writer
		if err := command.Start(); err != nil {
			return fmt.Errorf("cannot start %s: %w", path, err)
		}
		stop, followed := make(chan struct{}), make(chan struct{})
		go func() {
			follow(events, stop, happened)
			close(followed)
		}()
		done := make(chan error, 1)
		go func() {
			err := command.Wait()
			writer.Close()
			done <- err
		}()
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 64*1024), 1024*1024)
		for scanner.Scan() {
			said(scanner.Text())
		}
		// A line longer than the scanner takes ends the loop early, and ut-install
		// would then block writing to a pipe nobody reads.
		io.Copy(io.Discard, reader)
		err = <-done
		close(stop)
		<-followed
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return fmt.Errorf("ut-install exited with %d", exit.ExitCode())
		}
		return err
	}
}

func runPair(path string) Pairer {
	return func(ctx context.Context, args []string, stdin string, said func(string)) error {
		command := exec.CommandContext(ctx, path, args...)
		command.Stdin = strings.NewReader(stdin)
		reader, writer := io.Pipe()
		command.Stdout, command.Stderr = writer, writer
		if err := command.Start(); err != nil {
			return fmt.Errorf("cannot start %s: %w", path, err)
		}
		done := make(chan error, 1)
		go func() {
			err := command.Wait()
			writer.Close()
			done <- err
		}()
		scanner := bufio.NewScanner(reader)
		for scanner.Scan() {
			said(scanner.Text())
		}
		io.Copy(io.Discard, reader)
		return <-done
	}
}

var sessionKeys = []string{"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"}

// The variables a browser needs to reach a desktop session, read from the
// environment of one of its processes. Nothing is the same from one box to the
// next: on .40 the display was :1 under X11, with GDM's Xauthority.
func sessionVariables(environ []byte) []string {
	var kept []string
	desktop := false
	for _, entry := range strings.Split(string(environ), "\x00") {
		for _, key := range sessionKeys {
			if strings.HasPrefix(entry, key+"=") && len(entry) > len(key)+1 {
				kept = append(kept, entry)
				desktop = desktop || key == "DISPLAY" || key == "WAYLAND_DISPLAY"
			}
		}
	}
	if !desktop {
		return nil
	}
	return kept
}

// sudo keeps none of the desktop session's variables: the browser is opened as
// the user who ran sudo, with those of one of that user's graphical processes.
func browserCommand(name string, session []string, opener, address string) []string {
	command := append([]string{"runuser", "-u", name, "--", "env"}, session...)
	return append(command, opener, address)
}

// xdg-open answered "location is not supported" on .40, where no handler for
// web links was declared; Debian's x-www-browser named the browser installed.
func browserOpener() string {
	if _, err := exec.LookPath("x-www-browser"); err == nil {
		return "x-www-browser"
	}
	return "xdg-open"
}

func desktopSessionOf(uid string) []string {
	processes, _ := filepath.Glob("/proc/[0-9]*")
	for _, process := range processes {
		info, err := os.Stat(process)
		if err != nil {
			continue
		}
		if owner, ok := info.Sys().(*syscall.Stat_t); !ok || strconv.FormatUint(uint64(owner.Uid), 10) != uid {
			continue
		}
		environ, err := os.ReadFile(filepath.Join(process, "environ"))
		if err != nil {
			continue
		}
		if session := sessionVariables(environ); session != nil {
			return session
		}
	}
	return nil
}

func openTheDesktopBrowser(address string) {
	desktop, err := user.Lookup(os.Getenv("SUDO_USER"))
	if err != nil {
		return
	}
	session := desktopSessionOf(desktop.Uid)
	if session == nil {
		return
	}
	command := browserCommand(desktop.Username, session, browserOpener(), address)
	opener := exec.Command(command[0], command[1:]...)
	if opener.Start() == nil {
		go opener.Wait()
	}
}

func listen() (net.Listener, error) { return net.Listen("tcp", "127.0.0.1:0") }

func randomCode(length int) string {
	random := make([]byte, length)
	rand.Read(random)
	code := make([]byte, length)
	for i, b := range random {
		code[i] = codeAlphabet[int(b)%len(codeAlphabet)]
	}
	return string(code)
}

func randomHex(bytes int) string {
	random := make([]byte, bytes)
	rand.Read(random)
	return hex.EncodeToString(random)
}

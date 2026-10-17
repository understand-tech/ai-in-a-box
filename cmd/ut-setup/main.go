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
	"syscall"
	"time"
)

const codeAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("ut-setup", flag.ContinueOnError)
	flags.SetOutput(stderr)
	installer := flags.String("install", "ut-install", "the installer to run")
	if err := flags.Parse(args); err != nil {
		return 2
	}

	listener, err := listen()
	if err != nil {
		fmt.Fprintln(stderr, "ut-setup: cannot listen on this machine:", err)
		return 1
	}
	port := listener.Addr().(*net.TCPAddr).Port
	code, session := randomCode(20), randomHex(32)
	wizard := newWizard(runInstaller(*installer), code, session,
		fmt.Sprintf("127.0.0.1:%d", port), fmt.Sprintf("localhost:%d", port))

	server := &http.Server{Handler: wizard.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go server.Serve(listener)

	fmt.Fprintf(stdout, "Open this address in a browser on this machine:\n\n  http://127.0.0.1:%d/?code=%s\n\n", port, code)
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
	return func(ctx context.Context, args []string, line func(string)) error {
		command := exec.CommandContext(ctx, path, args...)
		command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
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
		scanner.Buffer(make([]byte, 64*1024), 1024*1024)
		for scanner.Scan() {
			line(scanner.Text())
		}
		err := <-done
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return fmt.Errorf("ut-install exited with %d", exit.ExitCode())
		}
		return err
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

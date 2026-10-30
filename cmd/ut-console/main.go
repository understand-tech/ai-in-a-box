package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	defaultPort       = 8443
	defaultAgent      = "/run/ut-agent/agent.sock"
	defaultConsoleDir = "/var/lib/understandtech/console"
)

const usage = `usage: ut-console <command>

  serve --domain NAME [--port 8443] [--agent SOCKET] [--dir DIR]
                  serves the administration console over HTTPS, to requests
                  that name NAME:PORT, and asks the agent on SOCKET for
                  everything it shows
  hash-password   reads a password on the standard input and prints the hash
                  the console checks it against
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "serve":
		return serve(args[1:], stderr)
	case "hash-password":
		if len(args) != 1 {
			fmt.Fprint(stderr, usage)
			return 2
		}
		return hashPasswordCommand(stdin, stdout, stderr)
	}
	fmt.Fprint(stderr, usage)
	return 2
}

// The agent answers on a Unix socket; the address in the URL is never dialled.
func agentClient(socket string) *http.Client {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	return &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", socket)
		},
	}}
}

// Read again whenever the agent replaces the file, so a renewal needs no
// restart; a file that does not load keeps the pair already served.
type certificateFile struct {
	path     string
	mu       sync.Mutex
	loadedAt time.Time
	pair     *tls.Certificate
}

func (f *certificateFile) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if info, err := os.Stat(f.path); err == nil && !info.ModTime().Equal(f.loadedAt) {
		if content, err := os.ReadFile(f.path); err == nil {
			if pair, err := tls.X509KeyPair(content, content); err == nil {
				f.pair, f.loadedAt = &pair, info.ModTime()
			}
		}
	}
	if f.pair == nil {
		return nil, errors.New("no certificate yet: ut-agent writes it")
	}
	return f.pair, nil
}

func serve(args []string, stderr io.Writer) int {
	flags := flag.NewFlagSet("ut-console serve", flag.ContinueOnError)
	flags.SetOutput(stderr)
	domain := flags.String("domain", "", "the address the console is opened at, UT_DOMAIN")
	port := flags.Int("port", defaultPort, "the port it listens on, on every interface")
	socket := flags.String("agent", defaultAgent, "the agent's socket")
	dir := flags.String("dir", defaultConsoleDir, "where the password hash and the certificate are")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *domain == "" || flags.NArg() != 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	host := fmt.Sprintf("%s:%d", strings.ToLower(*domain), *port)
	console := newConsole(host, agentClient(*socket), "http://agent", filepath.Join(*dir, "password"), time.Now)
	certificate := &certificateFile{path: filepath.Join(*dir, "tls.pem")}
	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", *port),
		Handler:           console.Handler(),
		TLSConfig:         &tls.Config{GetCertificate: certificate.get, MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      2 * agentTimeout,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    16 << 10,
	}
	fmt.Fprintf(stderr, "ut-console: answering https://%s\n", host)
	if err := server.ListenAndServeTLS("", ""); err != nil {
		fmt.Fprintln(stderr, "ut-console:", err)
		return 1
	}
	return 0
}

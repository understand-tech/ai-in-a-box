package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	defaultInstall  = "/usr/share/understandtech"
	defaultSettings = "/etc/understandtech"
	linkRootInCaddy = "/data/caddy/pki/authorities/link/root.crt"
	// After the first box is admitted, the window stays open a little for a
	// platform whose answer was lost to ask again with the same root.
	afterAdmission = time.Minute
)

const usage = `usage: ut-pair <command>

  offer           on a compute node: shows a pairing code and waits up to 15
                  minutes for one platform to pair with it
  join ADDRESS    on a platform: pairs with the node at ADDRESS (a name or an
                  IP, with :port if it is not 8444), reading the code the node
                  shows on standard input
  list            the boxes this one is linked to, by the fingerprint of their
                  root
  forget PREFIX   unlinks the box whose fingerprint starts with PREFIX: a node
                  stops serving it as soon as Caddy has reloaded
`

type Place struct {
	Install  string
	Settings string
	Now      func() time.Time
	Run      func(ctx context.Context, dir string, name string, args ...string) ([]byte, error)
}

func main() {
	place := Place{Install: defaultInstall, Settings: defaultSettings, Now: time.Now, Run: run}
	os.Exit(place.command(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func (p Place) command(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var err error
	switch {
	case len(args) == 1 && args[0] == "offer":
		err = p.offer(stdout)
	case len(args) == 2 && args[0] == "join":
		err = p.join(args[1], stdin, stdout)
	case len(args) == 1 && args[0] == "list":
		err = p.list(stdout)
	case len(args) == 2 && args[0] == "forget":
		err = p.forget(args[1], stdout)
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}
	if err != nil {
		fmt.Fprintln(stderr, "ut-pair:", err)
		return 1
	}
	return 0
}

func (p Place) caddy(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	return p.Run(ctx, p.Install, "docker", append([]string{"compose", "exec", "-T", "caddy"}, args...)...)
}

func (p Place) linkRoot() ([]byte, error) {
	output, err := p.caddy("cat", linkRootInCaddy)
	if err != nil {
		return nil, fmt.Errorf("cannot read this box's link root; is the stack up? %w", err)
	}
	block, _ := pem.Decode(output)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("this box's link root is not a certificate")
	}
	return block.Bytes, nil
}

func (p Place) reload() error {
	_, err := p.caddy("caddy", "reload", "--config", "/etc/caddy/Caddyfile")
	return err
}

func (p Place) trust(own []byte) Trust {
	system, _ := x509.SystemCertPool()
	return Trust{Own: own, System: system, Now: p.Now}
}

// A box joins the list, or nothing changes: if Caddy refuses the new list, the
// previous one is put back, so that a restart does not admit what failed here.
func (p Place) admit(root *x509.Certificate, from string) error {
	links, err := loadLinks(p.Settings)
	if err != nil {
		return err
	}
	if links.admits(root.Raw) {
		return nil
	}
	before := links
	links.Admitted = append(append([]Box(nil), links.Admitted...), Box{Root: root.Raw, Paired: p.Now().UTC(), From: from})
	if err := links.save(p.Settings); err != nil {
		return err
	}
	if err := p.reload(); err != nil {
		before.save(p.Settings)
		return err
	}
	return nil
}

func (p Place) offer(stdout io.Writer) error {
	own, err := p.linkRoot()
	if err != nil {
		return err
	}
	code, err := newCode(rand.Reader)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", ":"+strconv.Itoa(pairingPort))
	if err != nil {
		return fmt.Errorf("cannot listen on port %d: %w", pairingPort, err)
	}
	until := p.Now().Add(pairingWindow)
	offer := &Offer{Code: code, Trust: p.trust(own), Random: rand.Reader, Until: until}
	offer.Admit = func(root *x509.Certificate, from string) error {
		err := p.admit(root, from)
		if err == nil {
			fmt.Fprintf(stdout, "Admitted the box from %s, root %s\n", from, fingerprint(root.Raw))
		} else {
			fmt.Fprintf(stdout, "Could not admit the box from %s: %v\n", from, err)
		}
		return err
	}
	server := &http.Server{Handler: offer, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 2 * time.Minute}
	go server.Serve(listener)
	defer server.Close()

	fmt.Fprintf(stdout, "On the platform, until %s:\n\n  sudo ut-pair join <this machine's address>\n\nand give it this code:\n\n  %s\n\nThis node's root: %s\n",
		until.Format("15:04"), code, fingerprint(own))
	select {
	case <-offer.Admitted():
		time.Sleep(afterAdmission)
		return nil
	case <-time.After(time.Until(until)):
		return errors.New("no platform paired before the code expired")
	}
}

func (p Place) join(typed string, stdin io.Reader, stdout io.Writer) error {
	node, err := nodeAddress(typed)
	if err != nil {
		return err
	}
	own, err := p.linkRoot()
	if err != nil {
		return err
	}
	fmt.Fprint(stdout, "Code the node shows: ")
	line, err := bufio.NewReader(stdin).ReadString('\n')
	if err != nil && line == "" {
		return errors.New("no code given")
	}
	code, err := parseCode(line)
	if err != nil {
		return err
	}
	joiner := Joiner{Trust: p.trust(own), Random: rand.Reader, Client: &http.Client{Timeout: 2 * time.Minute}, Wait: time.Sleep}
	root, err := joiner.join(context.Background(), node, code)
	if err != nil {
		return err
	}
	links, err := loadLinks(p.Settings)
	if err != nil {
		return err
	}
	links.Node = &Node{Address: node, Root: root.Raw, Paired: p.Now().UTC()}
	if err := links.save(p.Settings); err != nil {
		return err
	}
	if err := p.reload(); err != nil {
		return fmt.Errorf("paired, but Caddy did not take the link: %w", err)
	}
	fmt.Fprintf(stdout, "Linked to the node at %s, root %s\n", node, fingerprint(root.Raw))
	return nil
}

func (p Place) list(stdout io.Writer) error {
	links, err := loadLinks(p.Settings)
	if err != nil {
		return err
	}
	for _, box := range links.Admitted {
		fmt.Fprintf(stdout, "admitted  %s  paired %s  from %s\n", fingerprint(box.Root), box.Paired.Format(time.DateOnly), box.From)
	}
	if links.Node != nil {
		fmt.Fprintf(stdout, "node      %s  paired %s  at %s\n", fingerprint(links.Node.Root), links.Node.Paired.Format(time.DateOnly), links.Node.Address)
	}
	if len(links.Admitted) == 0 && links.Node == nil {
		fmt.Fprintln(stdout, "This box is linked to no other.")
	}
	return nil
}

// Unlike admit, a refused reload keeps the new list: Caddy goes on serving
// the forgotten box until it restarts, and then it no longer does.
func (p Place) forget(prefix string, stdout io.Writer) error {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if len(prefix) < 8 {
		return errors.New("give at least the first 8 characters of the fingerprint ut-pair list shows")
	}
	links, err := loadLinks(p.Settings)
	if err != nil {
		return err
	}
	var kept []Box
	forgotten := 0
	for _, box := range links.Admitted {
		if strings.HasPrefix(fingerprint(box.Root), prefix) {
			forgotten++
			continue
		}
		kept = append(kept, box)
	}
	links.Admitted = kept
	if links.Node != nil && strings.HasPrefix(fingerprint(links.Node.Root), prefix) {
		links.Node = nil
		forgotten++
	}
	switch forgotten {
	case 0:
		return fmt.Errorf("no linked box has a fingerprint starting with %s", prefix)
	case 1:
	default:
		return fmt.Errorf("%d boxes have a fingerprint starting with %s; give more of it", forgotten, prefix)
	}
	if err := links.save(p.Settings); err != nil {
		return err
	}
	if err := p.reload(); err != nil {
		return fmt.Errorf("Caddy did not take the new list, and still serves that box until it restarts: %w", err)
	}
	fmt.Fprintf(stdout, "Forgot %s\n", prefix)
	return nil
}

package main

import (
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"unicode"
)

const maxTokenLength = 200

type answers struct {
	consent      string
	receiver     string
	tokenFile    string
	receiverCert string
}

func parseConfigure(args []string, stderr io.Writer) (answers, error) {
	var given answers
	flags := flag.NewFlagSet("configure", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&given.consent, "consent", "", "yes or no: whether this machine sends its usage reports")
	flags.StringVar(&given.receiver, "receiver", "", "https address of the receiver")
	flags.StringVar(&given.tokenFile, "token-file", "", "file holding this machine's token")
	flags.StringVar(&given.receiverCert, "receiver-cert", "", "the receiver's certificate, in PEM")
	if err := flags.Parse(args); err != nil {
		return answers{}, err
	}
	if flags.NArg() > 0 {
		return answers{}, fmt.Errorf("unexpected argument %q", flags.Arg(0))
	}
	if given.consent != "yes" && given.consent != "no" {
		return answers{}, errors.New("--consent must be yes or no: nothing is sent unless someone said yes")
	}
	return given, nil
}

func receiverAddress(raw string) (string, error) {
	address, err := url.Parse(raw)
	if err != nil || address.Scheme != "https" || address.Host == "" {
		return "", fmt.Errorf("--receiver must be an https address with a host, got %q", raw)
	}
	return address.String(), nil
}

func readToken(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("--token-file: %w", err)
	}
	token := strings.TrimRight(string(content), "\r\n")
	if token == "" || len(token) > maxTokenLength || strings.IndexFunc(token, unicode.IsSpace) >= 0 {
		return "", errors.New("--token-file must hold one token on one line, without spaces")
	}
	return token, nil
}

func readCertificate(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("--receiver-cert: %w", err)
	}
	block, _ := pem.Decode(content)
	if block == nil || block.Type != "CERTIFICATE" {
		return "", errors.New("--receiver-cert must be a PEM certificate")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return "", fmt.Errorf("--receiver-cert: %w", err)
	}
	return string(pem.EncodeToMemory(block)), nil
}

// Details given with a yes are added to those already kept, so the receiver
// can be named after the question was answered; a no drops all of them.
func decide(current Settings, given answers) (Settings, error) {
	if given.consent == "no" {
		return Settings{Consent: "no"}, nil
	}
	next := current
	next.Consent = "yes"
	var err error
	if given.receiver != "" {
		if next.Receiver, err = receiverAddress(given.receiver); err != nil {
			return Settings{}, err
		}
	}
	if given.tokenFile != "" {
		if next.Token, err = readToken(given.tokenFile); err != nil {
			return Settings{}, err
		}
	}
	if given.receiverCert != "" {
		if next.ReceiverCert, err = readCertificate(given.receiverCert); err != nil {
			return Settings{}, err
		}
	}
	return next, nil
}

func configure(args []string, path string, stdout, stderr io.Writer) int {
	given, err := parseConfigure(args, stderr)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send configure:", err)
		return 2
	}
	current, _, err := loadSettings(path)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send configure: the settings in place cannot be read:", err)
		return 1
	}
	next, err := decide(current, given)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send configure:", err)
		return 1
	}
	if err := saveSettings(path, next); err != nil {
		fmt.Fprintln(stderr, "ut-send configure:", err)
		return 1
	}
	fmt.Fprintln(stdout, describe(next, true))
	return 0
}

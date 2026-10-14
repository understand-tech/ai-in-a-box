package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maxAnswerBytes = 4096

var contentTypes = map[string]string{
	"report": "application/json",
	"usage":  "application/gzip",
}

type outcome int

const (
	accepted outcome = iota
	refused
	revoked
	unreachable
)

func receiverClient(settings Settings, timeout time.Duration) (*http.Client, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(settings.ReceiverCert)) {
		return nil, errors.New("the receiver's certificate cannot be read")
	}
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
			Proxy:           http.ProxyFromEnvironment,
		},
	}, nil
}

func receiverReason(body io.Reader) string {
	var answer struct {
		Message string `json:"message"`
	}
	content, _ := io.ReadAll(io.LimitReader(body, maxAnswerBytes))
	if json.Unmarshal(content, &answer) == nil && answer.Message != "" {
		return answer.Message
	}
	return strings.TrimSpace(string(content))
}

func deliver(client *http.Client, settings Settings, item Item, content []byte) (outcome, string) {
	sum := sha256.Sum256(content)
	request, err := http.NewRequest(http.MethodPost, strings.TrimRight(settings.Receiver, "/")+kinds[item.Kind], bytes.NewReader(content))
	if err != nil {
		return unreachable, err.Error()
	}
	request.Header.Set("Authorization", "Bearer "+settings.Token)
	request.Header.Set("X-Report-Sha256", hex.EncodeToString(sum[:]))
	request.Header.Set("Content-Type", contentTypes[item.Kind])
	response, err := client.Do(request)
	if err != nil {
		return unreachable, "receiver unreachable: " + err.Error()
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusCreated:
		return accepted, ""
	case response.StatusCode == http.StatusUnauthorized:
		return revoked, "token revoked or unknown to the receiver"
	default:
		return refused, fmt.Sprintf("%d %s", response.StatusCode, receiverReason(response.Body))
	}
}

// One pass, oldest first. A refusal keeps the deposit and moves on to the next;
// an unreachable receiver or a revoked token ends the pass, since every other
// deposit would meet the same answer.
func sendPass(place Place, settings Settings, stdout io.Writer) error {
	unlock, err := lockState(place.State)
	if errors.Is(err, errBusy) {
		fmt.Fprintln(stdout, "ut-send: another pass is sending; this one does nothing")
		return nil
	}
	if err != nil {
		return err
	}
	defer unlock()

	state, err := loadState(place.State)
	if err != nil {
		return err
	}
	if state.RevokedToken != "" && state.RevokedToken == fingerprint(settings.Token) {
		return nil
	}
	state.RevokedToken = ""

	now := place.Now()
	dir := queueDir(place.State)
	items, err := listQueue(dir)
	if err != nil {
		return err
	}
	keep, drop := prune(items, now, maxQueueBytes, maxAge)
	for _, item := range drop {
		if err := os.Remove(filepath.Join(dir, item.Name)); err != nil {
			return err
		}
		state.GivenUp++
	}

	client, err := receiverClient(settings, place.Timeout)
	if err != nil {
		return err
	}
	problem := ""
	for _, item := range keep {
		content, err := os.ReadFile(filepath.Join(dir, item.Name))
		if err != nil {
			return err
		}
		state.LastAttempt = now
		result, reason := deliver(client, settings, item, content)
		switch result {
		case accepted:
			if err := os.Remove(filepath.Join(dir, item.Name)); err != nil {
				return err
			}
			state.LastAccepted = now
			continue
		case revoked:
			state.RevokedToken = fingerprint(settings.Token)
		}
		problem = reason
		if result != refused {
			break
		}
	}
	state.LastProblem = problem
	return saveState(place.State, state)
}

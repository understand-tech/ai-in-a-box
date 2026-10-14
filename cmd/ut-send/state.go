package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

type State struct {
	LastAccepted time.Time `json:"last_accepted,omitempty"`
	LastAttempt  time.Time `json:"last_attempt,omitempty"`
	LastProblem  string    `json:"last_problem,omitempty"`
	RevokedToken string    `json:"revoked_token,omitempty"`
	GivenUp      int       `json:"given_up,omitempty"`
	LastExported int64     `json:"last_exported_ms,omitempty"`
	LastReported time.Time `json:"last_reported,omitempty"`
}

func statePath(dir string) string { return filepath.Join(dir, "state.json") }

func loadState(dir string) (State, error) {
	content, err := os.ReadFile(statePath(dir))
	if errors.Is(err, os.ErrNotExist) {
		return State{}, nil
	}
	if err != nil {
		return State{}, err
	}
	var state State
	err = json.Unmarshal(content, &state)
	return state, err
}

func saveState(dir string, state State) error {
	content, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return writeWhole(statePath(dir), append(content, '\n'), 0o600)
}

// Only a fingerprint is kept: the state file says which token was refused
// without holding a second copy of it.
func fingerprint(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:8])
}

// Written whole under another name and moved into place: an interrupted write
// never leaves a half file where the reader expects a whole one.
func writeWhole(path string, content []byte, mode os.FileMode) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".partial-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(content); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), path)
}

var errBusy = errors.New("another pass is sending")

func lockState(dir string) (func(), error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errBusy
		}
		return nil, err
	}
	return func() {
		syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		file.Close()
	}, nil
}

package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type Settings struct {
	Consent      string `json:"consent"`
	Receiver     string `json:"receiver,omitempty"`
	Token        string `json:"token,omitempty"`
	ReceiverCert string `json:"receiver_cert,omitempty"`
}

func (s Settings) ready() bool {
	return s.Consent == "yes" && s.Receiver != "" && s.Token != "" && s.ReceiverCert != ""
}

func loadSettings(path string) (Settings, bool, error) {
	content, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Settings{}, false, nil
	}
	if err != nil {
		return Settings{}, false, err
	}
	var settings Settings
	if err := json.Unmarshal(content, &settings); err != nil {
		return Settings{}, false, err
	}
	return settings, true, nil
}

// The token is in this file: it is written whole under another name and moved
// into place, so a crash never leaves it half-written or readable by others.
func saveSettings(path string, settings Settings) error {
	content, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".reporting-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(append(content, '\n')); err != nil {
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

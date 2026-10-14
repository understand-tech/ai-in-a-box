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

func saveSettings(path string, settings Settings) error {
	content, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	return writeWhole(path, append(content, '\n'))
}

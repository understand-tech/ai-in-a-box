package main

import (
	"bufio"
	"strings"
)

type Secrets struct {
	AdminPassword  string `json:"admin_password"`
	BackupPassword string `json:"backup_password"`
}

func readSecrets(settings string) Secrets {
	return Secrets{
		AdminPassword:  settingValue(settings, "ADMIN_SETUP_PASSWORD"),
		BackupPassword: settingValue(settings, "BACKUP_FILES_PASSWORD"),
	}
}

// Read as ut-install's env_get reads it: the first assignment, one layer of
// quotes taken off.
func settingValue(settings, key string) string {
	scanner := bufio.NewScanner(strings.NewReader(settings))
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

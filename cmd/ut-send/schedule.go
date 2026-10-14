package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	serviceName         = "ut-send.service"
	timerName           = "ut-send.timer"
	defaultEveryMinutes = 15
	maxEveryMinutes     = 24 * 60
	reportEvery         = time.Hour
)

func serviceUnit(place Place) string {
	return fmt.Sprintf(`[Unit]
Description=Send this machine's usage reports to UnderstandTech
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="UT_INSTALL_DIR=%s"
Environment="UT_SEND_SETTINGS=%s"
Environment="UT_SEND_STATE=%s"
ExecStart="%s" tick
`, place.Install, place.Settings, place.State, place.Self)
}

// OnActiveSec starts the count when the timer itself starts, at boot as when
// it is enabled; OnUnitActiveSec alone would never fire a first time. systemd's
// default accuracy of a minute doubled a one-minute period, measured.
func timerUnit(everyMinutes int) string {
	return fmt.Sprintf(`[Unit]
Description=Send this machine's usage reports every %d minutes

[Timer]
OnActiveSec=1min
OnUnitActiveSec=%dmin
AccuracySec=10s

[Install]
WantedBy=timers.target
`, everyMinutes, everyMinutes)
}

func systemctl(run Runner, args ...string) error {
	if output, err := run("", "systemctl", args...); err != nil {
		return fmt.Errorf("systemctl %v: %w %s", args, err, output)
	}
	return nil
}

// Restarted rather than only enabled: a timer already running keeps its old
// period until it is started again.
func schedule(place Place, run Runner, everyMinutes int) error {
	if err := os.MkdirAll(place.Units, 0o755); err != nil {
		return err
	}
	if err := writeWhole(filepath.Join(place.Units, serviceName), []byte(serviceUnit(place)), 0o644); err != nil {
		return err
	}
	if err := writeWhole(filepath.Join(place.Units, timerName), []byte(timerUnit(everyMinutes)), 0o644); err != nil {
		return err
	}
	for _, args := range [][]string{{"daemon-reload"}, {"enable", timerName}, {"restart", timerName}} {
		if err := systemctl(run, args...); err != nil {
			return err
		}
	}
	return nil
}

func unschedule(place Place, run Runner) error {
	timer := filepath.Join(place.Units, timerName)
	if _, err := os.Stat(timer); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err := systemctl(run, "disable", "--now", timerName); err != nil {
		return err
	}
	for _, unit := range []string{timer, filepath.Join(place.Units, serviceName)} {
		if err := os.Remove(unit); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return systemctl(run, "daemon-reload")
}

func scheduled(run Runner) bool {
	_, err := run("", "systemctl", "is-active", "--quiet", timerName)
	return err == nil
}

func reportIsDue(last, now time.Time) bool {
	return now.Sub(last) >= reportEvery
}

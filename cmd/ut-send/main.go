package main

import (
	"fmt"
	"io"
	"net/url"
	"os"
)

const defaultSettings = "/etc/understandtech/reporting.json"

const usage = `usage: ut-send <command>

  status      one line: whether this machine sends its usage reports, and where
  configure   --consent yes|no [--receiver https://host:port] [--token-file path]
              [--receiver-cert path]
              records the answer; details given with a yes are added to those
              already kept, a no forgets all of them
`

func describe(settings Settings, decided bool) string {
	switch {
	case !decided:
		return "Reporting: not decided"
	case settings.Consent != "yes":
		return "Reporting: off"
	case !settings.ready():
		return "Reporting: on, waiting for the receiver's address, token and certificate"
	}
	address, err := url.Parse(settings.Receiver)
	if err != nil {
		return "Reporting: on, to an address that cannot be read"
	}
	return "Reporting: on, to " + address.Host
}

func status(path string, stdout, stderr io.Writer) int {
	settings, decided, err := loadSettings(path)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send status: the settings cannot be read:", err)
		return 1
	}
	fmt.Fprintln(stdout, describe(settings, decided))
	return 0
}

func run(args []string, settingsPath string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "status":
		if len(args) != 1 {
			fmt.Fprint(stderr, usage)
			return 2
		}
		return status(settingsPath, stdout, stderr)
	case "configure":
		return configure(args[1:], settingsPath, stdout, stderr)
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}
}

func main() {
	path := os.Getenv("UT_SEND_SETTINGS")
	if path == "" {
		path = defaultSettings
	}
	os.Exit(run(os.Args[1:], path, os.Stdout, os.Stderr))
}

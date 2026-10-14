package main

import (
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"time"
)

const (
	defaultInstall  = "/usr/share/understandtech"
	defaultSettings = "/etc/understandtech/reporting.json"
	defaultState    = "/var/lib/understandtech/reporting"
	defaultUnits    = "/etc/systemd/system"
	sendTimeout     = 30 * time.Second
)

type Place struct {
	Install  string
	Settings string
	State    string
	Units    string
	Self     string
	Now      func() time.Time
	Timeout  time.Duration
}

const usage = `usage: ut-send <command>

  status      one line: whether this machine sends its usage reports, where,
              and how the last sends went
  configure   --consent yes|no [--receiver https://host:port] [--token-file path]
              [--receiver-cert path] [--every minutes]
              records the answer; details given with a yes are added to those
              already kept, a no forgets all of them. A yes starts a timer that
              runs tick every 15 minutes, or as often as --every says; a no
              removes it
  enqueue     report|usage <file>
              puts a copy of the file in line to be sent; refused without a yes
  collect     report: writes this machine's report — ut-report's, with the
              health of the stack and the use of each tool — and puts it in line
              usage: exports what the recorder kept since the last export, the
              customer's domain replaced by the surface it names
              both refused without a yes
  send        sends what is in line, oldest first; what the receiver does not
              take stays in line for up to 7 days
  tick        what the timer runs: collect usage, collect report once an hour,
              then send
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
	return fmt.Sprintf("Reporting: on, to %s, every %d minutes", address.Host, settings.every())
}

func describeSends(state State, waiting int, settings Settings) string {
	var line string
	if state.LastAccepted.IsZero() {
		line = "nothing accepted yet"
	} else {
		line = "last accepted " + state.LastAccepted.UTC().Format(time.RFC3339)
	}
	line += fmt.Sprintf(", %d waiting", waiting)
	if state.GivenUp > 0 {
		line += fmt.Sprintf(", %d given up after %d days", state.GivenUp, int(maxAge.Hours()/24))
	}
	if state.RevokedToken != "" && state.RevokedToken == fingerprint(settings.Token) {
		line += "; token revoked — give a new one with ut-send configure"
	} else if state.LastProblem != "" {
		line += "; last problem: " + state.LastProblem
	}
	return line
}

func status(place Place, run Runner, stdout, stderr io.Writer) int {
	settings, decided, err := loadSettings(place.Settings)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send status: the settings cannot be read:", err)
		return 1
	}
	fmt.Fprintln(stdout, describe(settings, decided))
	if settings.Consent == "yes" && !scheduled(run) {
		fmt.Fprintln(stdout, "  no timer runs it: nothing is collected or sent until ut-send configure --consent yes is given again")
	}
	if !settings.ready() {
		return 0
	}
	state, err := loadState(place.State)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send status: the state cannot be read:", err)
		return 1
	}
	items, err := listQueue(queueDir(place.State))
	if err != nil {
		fmt.Fprintln(stderr, "ut-send status: the queue cannot be read:", err)
		return 1
	}
	fmt.Fprintln(stdout, "  "+describeSends(state, len(items), settings))
	return 0
}

func enqueueCommand(args []string, place Place, stderr io.Writer) int {
	if len(args) != 2 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	settings, _, err := loadSettings(place.Settings)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send enqueue: the settings cannot be read:", err)
		return 1
	}
	if settings.Consent != "yes" {
		fmt.Fprintln(stderr, "ut-send enqueue: nobody said yes to sending reports; nothing is kept")
		return 1
	}
	content, err := os.ReadFile(args[1])
	if err != nil {
		fmt.Fprintln(stderr, "ut-send enqueue:", err)
		return 1
	}
	if err := enqueue(queueDir(place.State), args[0], content, place.Now()); err != nil {
		fmt.Fprintln(stderr, "ut-send enqueue:", err)
		return 1
	}
	return 0
}

func collectCommand(args []string, place Place, m machine, stdout, stderr io.Writer) int {
	if len(args) != 1 || (args[0] != "report" && args[0] != "usage") {
		fmt.Fprint(stderr, usage)
		return 2
	}
	settings, _, err := loadSettings(place.Settings)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send collect: the settings cannot be read:", err)
		return 1
	}
	if settings.Consent != "yes" {
		fmt.Fprintln(stderr, "ut-send collect: nobody said yes to sending reports; nothing is written")
		return 1
	}
	if err := os.MkdirAll(place.State, 0o700); err != nil {
		fmt.Fprintln(stderr, "ut-send collect:", err)
		return 1
	}
	if args[0] == "usage" {
		return usageCommand(place, m, stdout, stderr)
	}
	workDir, err := os.MkdirTemp(place.State, "collect-")
	if err != nil {
		fmt.Fprintln(stderr, "ut-send collect:", err)
		return 1
	}
	defer os.RemoveAll(workDir)
	report, err := collectReport(m, workDir)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send collect:", err)
		return 1
	}
	if err := enqueue(queueDir(place.State), "report", report, place.Now()); err != nil {
		fmt.Fprintln(stderr, "ut-send collect:", err)
		return 1
	}
	return 0
}

func usageCommand(place Place, m machine, stdout, stderr io.Writer) int {
	err := collectUsage(place, m)
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errNoRecorder), errors.Is(err, errBusy):
		fmt.Fprintln(stdout, "ut-send:", err)
		return 0
	}
	fmt.Fprintln(stderr, "ut-send collect usage:", err)
	return 1
}

func sendCommand(place Place, stdout, stderr io.Writer) int {
	settings, _, err := loadSettings(place.Settings)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send send: the settings cannot be read:", err)
		return 1
	}
	if !settings.ready() {
		return 0
	}
	if err := sendPass(place, settings, stdout); err != nil {
		fmt.Fprintln(stderr, "ut-send send:", err)
		return 1
	}
	return 0
}

// What the timer runs. A step that fails does not hold back the next: a
// recorder that is down still lets the hourly report and the sends go.
func tickCommand(place Place, m machine, stdout, stderr io.Writer) int {
	settings, _, err := loadSettings(place.Settings)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send tick: the settings cannot be read:", err)
		return 1
	}
	if settings.Consent != "yes" {
		fmt.Fprintln(stdout, "ut-send tick: nobody said yes to sending reports; nothing to do")
		return 0
	}
	failed := usageCommand(place, m, stdout, stderr) != 0
	state, err := loadState(place.State)
	if err != nil {
		fmt.Fprintln(stderr, "ut-send tick: the state cannot be read:", err)
		failed = true
	} else if reportIsDue(state.LastReported, place.Now()) {
		if collectCommand([]string{"report"}, place, m, stdout, stderr) != 0 {
			failed = true
		} else if err := markReported(place); err != nil {
			fmt.Fprintln(stderr, "ut-send tick:", err)
			failed = true
		}
	}
	if sendCommand(place, stdout, stderr) != 0 {
		failed = true
	}
	if failed {
		return 1
	}
	return 0
}

func runIn(args []string, place Place, stdout, stderr io.Writer) int {
	return runOn(args, place, machine{systemRunner, place.Install, statfsReader, containerOfProcess, ingressCertificate}, stdout, stderr)
}

func runOn(args []string, place Place, m machine, stdout, stderr io.Writer) int {
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
		return status(place, m.run, stdout, stderr)
	case "configure":
		return configure(args[1:], place, m.run, stdout, stderr)
	case "enqueue":
		return enqueueCommand(args[1:], place, stderr)
	case "collect":
		return collectCommand(args[1:], place, m, stdout, stderr)
	case "send":
		return sendCommand(place, stdout, stderr)
	case "tick":
		return tickCommand(place, m, stdout, stderr)
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}
}

func fromEnvironment(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func main() {
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut-send: cannot tell where this program is:", err)
		os.Exit(1)
	}
	place := Place{
		Install:  fromEnvironment("UT_INSTALL_DIR", defaultInstall),
		Settings: fromEnvironment("UT_SEND_SETTINGS", defaultSettings),
		State:    fromEnvironment("UT_SEND_STATE", defaultState),
		Units:    fromEnvironment("UT_SEND_UNITS", defaultUnits),
		Self:     self,
		Now:      time.Now,
		Timeout:  sendTimeout,
	}
	os.Exit(runIn(os.Args[1:], place, os.Stdout, os.Stderr))
}

package main

import (
	"fmt"
	"io"
	"os"
)

const usage = `usage: ut-send <command>

  status    one line: whether this machine sends its usage reports, and how the last send went
`

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "status":
		fmt.Fprintln(stdout, "Reporting: off")
		return 0
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

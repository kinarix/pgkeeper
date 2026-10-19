// SPDX-License-Identifier: Apache-2.0

// Command pgkeeper-instance is the instance manager: PID 1 in every Postgres
// container (02-instance-manager).
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/kinarix/pgkeeper/internal/instance"
)

const usage = `usage: pgkeeper-instance <command> [flags]

commands:
  install --to DIR [--wal-g PATH]   copy this binary and wal-g into DIR (init-copy delivery)
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "install":
		err = runInstall(os.Args[2:])
	// TODO(P2): run.
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "pgkeeper-instance %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}
}

func runInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	to := fs.String("to", "", "directory to copy the binaries into (required)")
	walg := fs.String("wal-g", "/wal-g", "path of the wal-g binary to copy")
	_ = fs.Parse(args)
	if *to == "" {
		fs.Usage()
		os.Exit(2)
	}
	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locating own binary: %w", err)
	}
	return instance.Install(*to, self, *walg)
}

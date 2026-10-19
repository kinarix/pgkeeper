// SPDX-License-Identifier: Apache-2.0

// Command pgkeeper-instance is the instance manager: PID 1 in every Postgres
// container (02-instance-manager).
package main

import (
	"fmt"
	"os"
)

func main() {
	// TODO(P0): install --to (init-copy delivery, 02 §2).
	// TODO(P2): run.
	fmt.Fprintln(os.Stderr, "pgkeeper-instance: no subcommands implemented yet")
	os.Exit(2)
}

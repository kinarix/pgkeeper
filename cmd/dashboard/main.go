// SPDX-License-Identifier: Apache-2.0

// Command dashboard serves the pgkeeper web dashboard (06-observability-dashboard).
package main

import (
	"fmt"
	"os"
)

func main() {
	// TODO(P24): OIDC login, impersonation, SSE status and live logs.
	fmt.Fprintln(os.Stderr, "pgkeeper-dashboard: not implemented yet")
	os.Exit(2)
}

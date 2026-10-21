// SPDX-License-Identifier: Apache-2.0

package main

import (
	"strings"
	"testing"
)

const valid = `---
id: 03-ha
title: "03 — HA"
type: spec
status: design
version: 0.2.0
updated: 2026-10-19
summary: "s"
phases: [P8]
topics: [ha]
references: [ADR-016]
changelog:
  - {version: 0.2.0, date: 2026-10-19, change: "b"}
  - {version: 0.1.0, date: 2026-10-16, change: "a"}
---

# 03 — HA
`

const adr = `---
id: ADR-016
title: "ADR-016 — Quorum lease"
type: adr
status: accepted
decided: 2026-10-16
version: 0.1.0
updated: 2026-10-16
phases: [P10b]
topics: [lease]
references: []
changelog:
  - {version: 0.1.0, date: 2026-10-16, change: "a"}
---
`

// rep returns valid with old replaced by repl, once.
func rep(old, repl string) string { return strings.Replace(valid, old, repl, 1) }

func TestCheckAll(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		doc  string // replaces 03-ha.md; ADR-016 is always present
		want string // substring of the one expected problem; "" = none
	}{
		{"valid", valid, ""},
		{"no front matter", "# 03 — HA\n", "does not start with"},
		{"unclosed", "---\nid: x\n", "no closing"},
		{"bad yaml", rep("phases: [P8]", "phases: [P8"), "not valid YAML"},
		{"version not in changelog", rep("version: 0.2.0\n", "version: 0.3.0\n"), "newest changelog entry"},
		{"updated not in changelog", rep("updated: 2026-10-19", "updated: 2026-10-20"), "newest changelog date"},
		{"missing key", rep("topics: [ha]\n", ""), `missing key "topics"`},
		{"unknown key", rep("summary:", "owner: me\nsummary:"), `unknown key "owner"`},
		{"out of order", rep("type: spec\nstatus: design\n", "status: design\ntype: spec\n"), `key "type" is out of order`},
		{"dangling reference", rep("[ADR-016]", "[ADR-099]"), `reference "ADR-099"`},
		{"duplicate id", rep("id: 03-ha", "id: ADR-016"), "is also used by"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := checkAll(map[string][]byte{"03-ha.md": []byte(tt.doc), "016.md": []byte(adr)})
			var all []string
			for _, ps := range got {
				all = append(all, ps...)
			}
			if tt.want == "" {
				if len(all) != 0 {
					t.Fatalf("want no problems, got %q", all)
				}
				return
			}
			if len(all) != 1 || !strings.Contains(all[0], tt.want) {
				t.Fatalf("want one problem containing %q, got %q", tt.want, all)
			}
		})
	}
}

// SPDX-License-Identifier: Apache-2.0

// Command frontmatter checks the YAML front matter of the Markdown files
// given as arguments (CLAUDE.md working rule 8). Run by make verify.
package main

import (
	"fmt"
	"maps"
	"os"
	"slices"
)

func main() {
	files := map[string][]byte{}
	for _, path := range os.Args[1:] {
		b, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "frontmatter: %v\n", err)
			os.Exit(1)
		}
		files[path] = b
	}
	problems := checkAll(files)
	for _, path := range slices.Sorted(maps.Keys(problems)) {
		for _, p := range problems[path] {
			fmt.Printf("%s: %s\n", path, p)
		}
	}
	if len(problems) > 0 {
		fmt.Println("frontmatter: fix the problems above (CLAUDE.md working rule 8)")
		os.Exit(1)
	}
}

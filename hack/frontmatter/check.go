// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"fmt"
	"slices"

	"go.yaml.in/yaml/v3"
)

// fieldOrder is the key order from CLAUDE.md working rule 8. Keys marked
// optional may be absent; present keys must appear in this order.
type field struct {
	key      string
	optional bool
}

var fieldOrder = []field{
	{"id", false}, {"title", false}, {"type", false}, {"status", false},
	{"superseded_by", true}, {"status_note", true}, {"decided", true},
	{"supersedes", true}, {"amends", true}, {"amended_by", true},
	{"version", false}, {"updated", false}, {"summary", true},
	{"phases", false}, {"topics", false}, {"references", false},
	{"related", true}, {"changelog", false},
}

type change struct {
	Version string `yaml:"version"`
	Date    string `yaml:"date"`
	Change  string `yaml:"change"`
}

type doc struct {
	ID           string   `yaml:"id"`
	Version      string   `yaml:"version"`
	Updated      string   `yaml:"updated"`
	References   []string `yaml:"references"`
	SupersededBy string   `yaml:"superseded_by"`
	Changelog    []change `yaml:"changelog"`
}

// parse extracts and checks the front matter of one Markdown file. It
// returns the parsed block and every problem found in it.
func parse(content []byte) (doc, []string) {
	var d doc
	rest, ok := bytes.CutPrefix(content, []byte("---\n"))
	if !ok {
		return d, []string{"does not start with a '---' front matter line"}
	}
	block, _, ok := bytes.Cut(rest, []byte("\n---\n"))
	if !ok {
		return d, []string{"front matter has no closing '---' line"}
	}

	var node yaml.Node
	if err := yaml.Unmarshal(block, &node); err != nil {
		return d, []string{fmt.Sprintf("front matter is not valid YAML: %v", err)}
	}
	if len(node.Content) != 1 || node.Content[0].Kind != yaml.MappingNode {
		return d, []string{"front matter is not a YAML mapping"}
	}
	var problems []string
	problems = append(problems, checkOrder(node.Content[0])...)
	if err := node.Content[0].Decode(&d); err != nil {
		return d, append(problems, fmt.Sprintf("decoding front matter: %v", err))
	}

	switch {
	case len(d.Changelog) == 0:
		problems = append(problems, "changelog is empty")
	case d.Changelog[0].Version != d.Version:
		problems = append(problems, fmt.Sprintf("version %s does not match newest changelog entry %s",
			d.Version, d.Changelog[0].Version))
	case d.Changelog[0].Date != d.Updated:
		problems = append(problems, fmt.Sprintf("updated %s does not match newest changelog date %s",
			d.Updated, d.Changelog[0].Date))
	}
	return d, problems
}

func checkOrder(m *yaml.Node) []string {
	var keys []string
	for i := 0; i < len(m.Content); i += 2 {
		keys = append(keys, m.Content[i].Value)
	}
	var problems []string
	pos := 0
	for _, k := range keys {
		idx := slices.IndexFunc(fieldOrder, func(f field) bool { return f.key == k })
		switch {
		case idx < 0:
			problems = append(problems, fmt.Sprintf("unknown key %q", k))
		case idx < pos:
			problems = append(problems, fmt.Sprintf("key %q is out of order", k))
		default:
			pos = idx
		}
	}
	for _, f := range fieldOrder {
		if !f.optional && !slices.Contains(keys, f.key) {
			problems = append(problems, fmt.Sprintf("missing key %q", f.key))
		}
	}
	return problems
}

// checkAll checks every file and that references resolve to known ids.
// files maps path to content; the result maps path to its problems.
func checkAll(files map[string][]byte) map[string][]string {
	docs := map[string]doc{}
	out := map[string][]string{}
	ids := map[string]string{}
	for path, content := range files {
		d, problems := parse(content)
		docs[path] = d
		if prev, dup := ids[d.ID]; dup && d.ID != "" {
			problems = append(problems, fmt.Sprintf("id %q is also used by %s", d.ID, prev))
		}
		ids[d.ID] = path
		if len(problems) > 0 {
			out[path] = problems
		}
	}
	for path, d := range docs {
		refs := d.References
		if d.SupersededBy != "" {
			refs = append(slices.Clone(refs), d.SupersededBy)
		}
		for _, r := range refs {
			if _, ok := ids[r]; !ok {
				out[path] = append(out[path], fmt.Sprintf("reference %q matches no document id", r))
			}
		}
	}
	return out
}

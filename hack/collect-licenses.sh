#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Copy the LICENSE/NOTICE/COPYING files of every module linked into a Go
# binary to <out>/<module path>/ (02 §2: /LICENSES in the tools image).
# Fails if a module ships no license file.
#
# Usage: collect-licenses.sh <out> <module dir> <package> [go list env...]
set -euo pipefail

out=$1 moddir=$2 pkg=$3
shift 3

missing=0
while read -r path dir; do
	[[ -n "$dir" ]] || continue
	files=$(find "$dir" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'NOTICE*' -o -iname 'COPYING*' \))
	if [[ -z "$files" ]]; then
		echo "collect-licenses: no license file in $path ($dir)" >&2
		missing=1
		continue
	fi
	mkdir -p "$out/$path"
	while read -r f; do cp "$f" "$out/$path/"; done <<<"$files"
done < <(cd "$moddir" && env "$@" go list -deps -f '{{with .Module}}{{.Path}} {{.Dir}}{{end}}' "$pkg" | sort -u)
chmod -R u+w "$out"
exit "$missing"

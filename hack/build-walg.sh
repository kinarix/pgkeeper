#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build a static, cgo-free WAL-G (Postgres flavour) from a pinned commit
# (02 §2, ADR-006). No build tags: brotli, libsodium and lzo need cgo, so
# compression is limited to lz4/zstd/lzma.
#
# The source comes from the Go module cache: checksum-verified against the
# sum database on first download, available offline afterwards, and outside
# this repo so ./... tooling never sees it.
#
# Usage: build-walg.sh <commit> <version> <output> (GOOS/GOARCH from env)
set -euo pipefail

commit=$1 version=$2 output=$3

src=$(cd "${TMPDIR:-/tmp}" && GOFLAGS=-mod=mod go mod download -json "github.com/wal-g/wal-g@$commit" |
	sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')
if [[ -z "$src" ]]; then
	echo "build-walg: go mod download of wal-g@$commit failed" >&2
	exit 1
fi

# WAL-G imports encoding/json/v2, which needs the jsonv2 experiment on Go 1.26.
(cd "$src" && CGO_ENABLED=0 GOEXPERIMENT=jsonv2 go build -trimpath \
	-ldflags "-s -w -X github.com/wal-g/wal-g/cmd/pg.walgVersion=$version -X github.com/wal-g/wal-g/cmd/pg.gitRevision=$commit" \
	-o "$output" ./main/pg)

if ! go version -m "$output" | grep -q 'CGO_ENABLED=0'; then
	echo "build-walg: $output was not built with CGO_ENABLED=0" >&2
	exit 1
fi
echo "build-walg: $output ($version, $commit)"

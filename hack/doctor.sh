#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Check developer prerequisites (08 §1): docker running with enough memory and
# CPU, go at least the go.mod version, registry ports free or ours.
set -euo pipefail

fail=0
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }

if ! docker info >/dev/null 2>&1; then
	bad "docker is not running: start Docker Desktop / the docker daemon"
	exit 1
fi
read -r cpus mem < <(docker info --format '{{.NCPU}} {{.MemTotal}}')
# A Docker Desktop "8 GB" setting reports ~7.75 GiB.
if ((mem >= 7900000000)); then ok "docker memory $((mem / 1024 / 1024)) MiB"; else
	bad "docker memory $((mem / 1024 / 1024)) MiB: allot at least 8 GB to Docker"; fi
if ((cpus >= 4)); then ok "docker cpus $cpus"; else bad "docker cpus $cpus: allot at least 4"; fi

want=$(sed -n 's/^go \([0-9.]*\)$/\1/p' go.mod)
have=$(go env GOVERSION | sed 's/^go//')
if [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" == "$want" ]]; then
	ok "go $have (go.mod wants $want)"
else
	bad "go $have is older than go.mod's $want"
fi

for spec in 5001:kind-registry 5002:k3d-registry.localhost; do
	port=${spec%%:*} owner=${spec#*:}
	user=$(docker ps --filter "publish=$port" --format '{{.Names}}')
	if [[ -z "$user" ]] && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
		bad "port $port is in use by a non-docker process (needed by $owner)"
	elif [[ -n "$user" && "$user" != "$owner" ]]; then
		bad "port $port is used by container $user (needed by $owner)"
	else
		ok "port $port free or used by $owner"
	fi
done
exit "$fail"

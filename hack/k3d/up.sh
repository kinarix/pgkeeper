#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Create the k3d cluster and its registry (08 §4). Idempotent.
# Images pushed to localhost:<port>/... on the host are pulled by nodes under
# the same name: registries.yaml mirrors localhost:<port> to the registry
# container, so no /etc/hosts entry for k3d-registry.localhost is needed.
#
# Usage: up.sh <k3d> <cluster> <k3s image> <registry port>
set -euo pipefail

k3d=$1 cluster=$2 k3s_image=$3 port=$4
reg=registry.localhost

if ! "$k3d" registry list -o json | grep -q "\"k3d-$reg\""; then
	"$k3d" registry create "$reg" --port "127.0.0.1:$port"
fi

if "$k3d" cluster list -o json | grep -q "\"name\":\"$cluster\""; then
	echo "k3d cluster $cluster already exists"
	"$k3d" cluster start "$cluster" >/dev/null
else
	registries=$(mktemp)
	trap 'rm -f "$registries"' EXIT
	cat >"$registries" <<YAML
mirrors:
  "localhost:$port":
    endpoint:
      - http://k3d-$reg:5000
YAML
	"$k3d" cluster create "$cluster" --config "$(dirname "$0")/k3d-config.yaml" \
		--image "$k3s_image" --registry-use "k3d-$reg:$port" \
		--registry-config "$registries" --wait --timeout 5m
fi
echo "k3d cluster $cluster ready (context k3d-$cluster, registry localhost:$port)"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Create the kind cluster and its local registry (08 §4). Idempotent.
# Images pushed to localhost:<port>/... on the host are pulled by nodes under
# the same name, through a containerd mirror to the registry container.
#
# Usage: up.sh <kind> <cluster> <node image> <registry image> <registry port>
set -euo pipefail

kind=$1 cluster=$2 node_image=$3 registry_image=$4 port=$5
reg=kind-registry

if [[ "$(docker inspect -f '{{.State.Running}}' "$reg" 2>/dev/null)" != true ]]; then
	docker rm -f "$reg" >/dev/null 2>&1 || true
	docker run -d --restart=always --name "$reg" -p "127.0.0.1:$port:5000" "$registry_image" >/dev/null
fi

if "$kind" get clusters | grep -qx "$cluster"; then
	echo "kind cluster $cluster already exists"
else
	"$kind" create cluster --name "$cluster" --image "$node_image" \
		--config "$(dirname "$0")/kind-config.yaml" --wait 5m
fi

for node in $("$kind" get nodes --name "$cluster"); do
	dir=/etc/containerd/certs.d/localhost:$port
	docker exec "$node" mkdir -p "$dir"
	printf '[host."http://%s:5000"]\n' "$reg" | docker exec -i "$node" cp /dev/stdin "$dir/hosts.toml"
done

if [[ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$reg")" == null ]]; then
	docker network connect kind "$reg"
fi

# Advertise the registry (KEP-1755).
"${KUBECTL:-kubectl}" --context "kind-$cluster" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:$port"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
YAML
echo "kind cluster $cluster ready (context kind-$cluster, registry localhost:$port)"

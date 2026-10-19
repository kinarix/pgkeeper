#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run `wal-g --version` in a postgres:18 pod with the tools image delivered
# by image volume or by init-copy (02 §2), and print its output.
#
# Usage: walg-pod.sh <kubectl> <context> <tools image> <image-volume|init-copy>
set -euo pipefail

kubectl=$1 ctx=$2 img=$3 mode=$4
k() { "$kubectl" --context "$ctx" -n default "$@"; }

if [[ $mode == image-volume ]]; then
	init='[]'
	vol="{name: tools, image: {reference: \"$img\", pullPolicy: IfNotPresent}}"
else
	init="[{name: install, image: \"$img\", args: [install, --to, /pgkeeper/bin], volumeMounts: [{name: tools, mountPath: /pgkeeper/bin}]}]"
	vol='{name: tools, emptyDir: {}}'
fi

k delete pod walg-probe --ignore-not-found --wait >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: walg-probe}
spec:
  restartPolicy: Never
  initContainers: $init
  containers:
    - name: pg
      image: postgres:18-trixie
      command: [/pgkeeper/bin/wal-g, --version]
      volumeMounts: [{name: tools, mountPath: /pgkeeper/bin, readOnly: true}]
  volumes: [$vol]
YAML
if ! k wait pod/walg-probe --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m >/dev/null; then
	k describe pod walg-probe >&2
	exit 1
fi
k logs walg-probe -c pg
k delete pod walg-probe --wait=false >/dev/null

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0 acceptance (09-phases.md). Creates and deletes local clusters named
# pgkeeper and pgkeeper-134; restores the caller's kube context on exit.
set -euo pipefail

kubectl=./bin/kubectl
orig=$("$kubectl" config current-context 2>/dev/null || true)
trap '[[ -n "$orig" ]] && "$kubectl" config use-context "$orig" >/dev/null' EXIT
step() { printf '\n=== accept-p0: %s\n' "$*"; }
tag=$(make -s print-IMG_TAG)

step "doctor tools verify lint test"
make doctor tools verify lint test

step "dco"
hack/dco_test.sh

for p in kind k3d; do
	step "$p: cluster-up twice"
	make CLUSTER_PROVIDER=$p cluster-up
	make CLUSTER_PROVIDER=$p cluster-up

	step "$p: docker-build images-load deploy, operator Ready"
	make CLUSTER_PROVIDER=$p docker-build images-load deploy
	reg=$(make -s CLUSTER_PROVIDER=$p print-LOCAL_REGISTRY)

	step "$p: wal-g in postgres:18 via image volume"
	hack/accept/walg-pod.sh "$kubectl" "$p-pgkeeper" "$reg/pgkeeper-tools:$tag" image-volume
done

step "kind 1.34: wal-g in postgres:18 via init-copy"
make CLUSTER_NAME=pgkeeper-134 KIND_K8S_VERSION=1.34 cluster-up
make CLUSTER_NAME=pgkeeper-134 images-load
hack/accept/walg-pod.sh "$kubectl" kind-pgkeeper-134 "localhost:5001/pgkeeper-tools:$tag" init-copy

for c in "CLUSTER_PROVIDER=kind" "CLUSTER_PROVIDER=kind CLUSTER_NAME=pgkeeper-134" "CLUSTER_PROVIDER=k3d"; do
	step "$c: cluster-down twice"
	# shellcheck disable=SC2086
	make $c cluster-down && make $c cluster-down
done
step "PASSED"

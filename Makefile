# SPDX-License-Identifier: Apache-2.0
#
# Makefile contract: docs/specs/08-testing-and-makefile.md §5.
# Tools live in ./bin as versioned files with an unversioned symlink.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

IMG_REGISTRY ?= ghcr.io/kinarix
IMG_TAG ?= $(shell git describe --tags --dirty --always)
# Image volumes default to pullPolicy Always for :latest, which breaks local
# registries and pinning (02 §2).
ifeq ($(IMG_TAG),latest)
$(error IMG_TAG must not be "latest")
endif
TOOLS_IMG ?= $(IMG_REGISTRY)/pgkeeper-tools:$(IMG_TAG)
IMAGES := pgkeeper-operator pgkeeper-tools pgkeeper-dashboard

CLUSTER_PROVIDER ?= kind
CLUSTER_NAME ?= pgkeeper
KIND_K8S_VERSION ?= 1.36
KIND_REGISTRY_PORT ?= 5001
K3D_REGISTRY_PORT ?= 5002
ifeq ($(CLUSTER_PROVIDER),kind)
KUBE_CONTEXT := kind-$(CLUSTER_NAME)
LOCAL_REGISTRY := localhost:$(KIND_REGISTRY_PORT)
else ifeq ($(CLUSTER_PROVIDER),k3d)
KUBE_CONTEXT := k3d-$(CLUSTER_NAME)
LOCAL_REGISTRY := localhost:$(K3D_REGISTRY_PORT)
else
$(error CLUSTER_PROVIDER must be kind or k3d, got "$(CLUSTER_PROVIDER)")
endif
# Registry the deployed cluster pulls from; the local one unless overridden.
DEPLOY_REGISTRY ?= $(LOCAL_REGISTRY)
KUBECTL_CTX = "$(KUBECTL)" --context "$(KUBE_CONTEXT)"

# require-local-context refuses to touch a cluster whose current context is
# not this repo's local one (08 §5.1 rule 7). Targets also pass --context
# explicitly, so a context switch mid-run cannot redirect them.
define require-local-context
@ctx="$$("$(KUBECTL)" config current-context 2>/dev/null || true)"; \
if [ "$$ctx" != "$(KUBE_CONTEXT)" ] && [ "$${ALLOW_NON_LOCAL:-}" != 1 ]; then \
	echo "refusing to run: current kube context is '$$ctx', expected '$(KUBE_CONTEXT)'."; \
	echo "Run 'make cluster-up' or 'kubectl config use-context $(KUBE_CONTEXT)'."; \
	exit 1; \
fi
endef

##@ General

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: tools
tools: controller-gen setup-envtest golangci-lint kustomize kind k3d kubectl ## Install all pinned tools into ./bin

.PHONY: doctor
doctor: ## Check prerequisites (docker resources, go version, ports)
	@hack/doctor.sh

##@ Development

.PHONY: fmt
fmt: golangci-lint ## go fmt + goimports
	go fmt ./...
	"$(GOLANGCI_LINT)" fmt

.PHONY: vet
vet: ## go vet
	go vet ./...

.PHONY: lint
lint: golangci-lint ## golangci-lint run
	"$(GOLANGCI_LINT)" run

.PHONY: generate
generate: controller-gen ## controller-gen object (deepcopy)
	"$(CONTROLLER_GEN)" object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: manifests
manifests: controller-gen ## controller-gen crd rbac → config/crd, config/rbac
	"$(CONTROLLER_GEN)" rbac:roleName=manager-role crd paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: verify
verify: generate manifests fmt ## generate+manifests+fmt then fail if git diff is non-empty
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "verify: working tree differs after generate/manifests/fmt:"; \
		git status --porcelain; git --no-pager diff --stat; \
		echo "Run 'make generate manifests fmt' and commit the result."; \
		exit 1; \
	fi

DCO_BASE ?= origin/main

.PHONY: dco
dco: ## Check every commit in $(DCO_BASE)..HEAD has a DCO sign-off by its author
	@hack/dco.sh "$(DCO_BASE)"

##@ Test

.PHONY: test
test: test-unit test-envtest ## test-unit + test-envtest

.PHONY: test-unit
test-unit: ## Unit + property tests (-race)
	go test -race ./...

.PHONY: test-envtest
test-envtest: setup-envtest ## envtest integration (downloads envtest assets via setup-envtest)
	KUBEBUILDER_ASSETS="$$("$(ENVTEST)" use $(ENVTEST_K8S_VERSION) --bin-dir "$(LOCALBIN)" -p path)" \
		go test -race -tags envtest ./...

##@ Build

.PHONY: build
build: ## Build all binaries into ./bin (operator, instance, dashboard)
	CGO_ENABLED=0 go build -trimpath -o "$(LOCALBIN)/pgkeeper-operator" ./cmd/operator
	CGO_ENABLED=0 go build -trimpath -o "$(LOCALBIN)/pgkeeper-instance" ./cmd/instance
	CGO_ENABLED=0 go build -trimpath -o "$(LOCALBIN)/pgkeeper-dashboard" ./cmd/dashboard

# Linux binaries for images; GOARCH defaults to the host's.
GOARCH ?= $(shell go env GOARCH)
WALG = $(LOCALBIN)/wal-g-$(WALG_VERSION)-linux-$(GOARCH)

.PHONY: build-walg
build-walg: $(LOCALBIN) ## Build static WAL-G from $(WALG_COMMIT)
	@[ -f "$(WALG)" ] || GOOS=linux GOARCH=$(GOARCH) hack/build-walg.sh $(WALG_COMMIT) $(WALG_VERSION) "$(WALG)"

.PHONY: docker-build
docker-build: docker-build-tools docker-build-operator docker-build-dashboard ## Build images: operator, tools (instance + wal-g), dashboard

IMAGE_CONTEXT = $(LOCALBIN)/image-$(1)-linux-$(GOARCH)

# stage-go-binary builds ./cmd/$(2) as $(3) into image context $(1) and
# collects the licenses of every module linked into it.
define stage-go-binary
CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -trimpath -ldflags "-s -w" -o "$(1)/$(3)" ./cmd/$(2)
hack/collect-licenses.sh "$(1)/LICENSES/$(3)" . ./cmd/$(2) GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0
endef

.PHONY: docker-build-tools
docker-build-tools: build-walg
	rm -rf "$(call IMAGE_CONTEXT,tools)" && mkdir -p "$(call IMAGE_CONTEXT,tools)/LICENSES"
	$(call stage-go-binary,$(call IMAGE_CONTEXT,tools),instance,pgkeeper-instance)
	cp "$(WALG)" "$(call IMAGE_CONTEXT,tools)/wal-g"
	hack/collect-licenses.sh "$(call IMAGE_CONTEXT,tools)/LICENSES/wal-g" "$$(cd "$${TMPDIR:-/tmp}" && go mod download -json github.com/wal-g/wal-g@$(WALG_COMMIT) | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$$/\1/p')" ./main/pg GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0 GOEXPERIMENT=jsonv2
	docker build --platform linux/$(GOARCH) -f images/tools/Dockerfile -t "$(TOOLS_IMG)" "$(call IMAGE_CONTEXT,tools)"

.PHONY: docker-build-operator docker-build-dashboard
docker-build-operator docker-build-dashboard: docker-build-%:
	rm -rf "$(call IMAGE_CONTEXT,$*)" && mkdir -p "$(call IMAGE_CONTEXT,$*)/LICENSES"
	$(call stage-go-binary,$(call IMAGE_CONTEXT,$*),$*,pgkeeper-$*)
	docker build --platform linux/$(GOARCH) -f images/$*/Dockerfile -t "$(IMG_REGISTRY)/pgkeeper-$*:$(IMG_TAG)" "$(call IMAGE_CONTEXT,$*)"

.PHONY: images-load
images-load: ## Push images to the local $(CLUSTER_PROVIDER) registry
	@for img in $(IMAGES); do \
		docker tag "$(IMG_REGISTRY)/$$img:$(IMG_TAG)" "$(LOCAL_REGISTRY)/$$img:$(IMG_TAG)"; \
		docker push -q "$(LOCAL_REGISTRY)/$$img:$(IMG_TAG)"; \
	done

##@ Local cluster

.PHONY: cluster-up
cluster-up: $(CLUSTER_PROVIDER)-up ## Create $(CLUSTER_PROVIDER) cluster + local registry (idempotent)

.PHONY: cluster-down
cluster-down: $(CLUSTER_PROVIDER)-down ## Delete it

.PHONY: kind-up
kind-up: doctor kind kubectl ## kind variant of cluster-up
	KUBECTL="$(KUBECTL)" hack/kind/up.sh "$(KIND)" $(CLUSTER_NAME) "$(KIND_NODE_IMAGE)" "$(REGISTRY_IMAGE)" $(KIND_REGISTRY_PORT)

.PHONY: kind-down
kind-down: kind ## kind variant of cluster-down (keeps the registry and its cache)
	"$(KIND)" delete cluster --name $(CLUSTER_NAME)

.PHONY: k3d-up
k3d-up: doctor k3d kubectl ## k3d variant of cluster-up
	hack/k3d/up.sh "$(K3D)" $(CLUSTER_NAME) "$(K3S_IMAGE)" $(K3D_REGISTRY_PORT)

.PHONY: k3d-down
k3d-down: k3d ## k3d variant of cluster-down (keeps the registry and its cache)
	@if "$(K3D)" cluster list -o json | grep -q '"name":"$(CLUSTER_NAME)"'; then \
		"$(K3D)" cluster delete $(CLUSTER_NAME); \
	else echo "k3d cluster $(CLUSTER_NAME) does not exist"; fi

##@ Deploy

.PHONY: install
install: manifests kustomize kubectl ## Apply CRDs only
	$(require-local-context)
	@out="$$("$(KUSTOMIZE)" build config/crd 2>/dev/null || true)"; \
	if [ -n "$$out" ]; then echo "$$out" | $(KUBECTL_CTX) apply --server-side -f -; \
	else echo "No CRDs to install yet."; fi  # TODO(P1): config/crd

.PHONY: uninstall
uninstall: kustomize kubectl ## Delete CRDs (refuses if any PostgresCluster exists unless FORCE=1)
	$(require-local-context)
	@n="$$($(KUBECTL_CTX) get postgresclusters.pgkeeper.in -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"; \
	if [ "$$n" != 0 ] && [ "$${FORCE:-}" != 1 ]; then \
		echo "refusing: $$n PostgresCluster(s) exist; delete them or set FORCE=1"; exit 1; fi
	@out="$$("$(KUSTOMIZE)" build config/crd 2>/dev/null || true)"; \
	if [ -n "$$out" ]; then echo "$$out" | $(KUBECTL_CTX) delete --ignore-not-found -f -; \
	else echo "No CRDs to delete."; fi

DEPLOY_DIR = $(CURDIR)/config/_deploy

# render-deploy writes a throwaway overlay of config/$(1) that sets the image
# names, so deploying never edits tracked files.
define render-deploy
rm -rf "$(DEPLOY_DIR)" && mkdir -p "$(DEPLOY_DIR)"
printf '%s\n' \
	'apiVersion: kustomize.config.k8s.io/v1beta1' \
	'kind: Kustomization' \
	'resources: ["../$(1)"]' \
	'images:' \
	'  - name: pgkeeper-operator' \
	'    newName: $(DEPLOY_REGISTRY)/pgkeeper-operator' \
	'    newTag: "$(IMG_TAG)"' >"$(DEPLOY_DIR)/kustomization.yaml"
endef

.PHONY: deploy
deploy: manifests kustomize kubectl ## Deploy operator with images from IMG_* (dashboard: TODO(P24))
	$(require-local-context)
	$(call render-deploy,default)
	"$(KUSTOMIZE)" build "$(DEPLOY_DIR)" | $(KUBECTL_CTX) apply --server-side -f -
	$(KUBECTL_CTX) -n pgkeeper-system rollout status deployment/pgkeeper-controller-manager --timeout=3m

.PHONY: deploy-dev
deploy-dev: manifests kustomize kubectl ## deploy with debug logging, 1 replica
	$(require-local-context)
	$(call render-deploy,overlays/dev)
	"$(KUSTOMIZE)" build "$(DEPLOY_DIR)" | $(KUBECTL_CTX) apply --server-side -f -
	$(KUBECTL_CTX) -n pgkeeper-system rollout status deployment/pgkeeper-controller-manager --timeout=3m

.PHONY: undeploy
undeploy: kustomize kubectl ## Remove the operator
	$(require-local-context)
	$(call render-deploy,default)
	"$(KUSTOMIZE)" build "$(DEPLOY_DIR)" | $(KUBECTL_CTX) delete --ignore-not-found -f -

.PHONY: dev
dev: cluster-up install docker-build images-load deploy-dev ## cluster-up + install + docker-build + images-load + deploy-dev
	@# TODO(P3): infra-up and samples once there is something to run against them.

##@ E2E

# TODO(P3): chainsaw + Go e2e behind these stubs.
.PHONY: e2e e2e-smoke e2e-ha e2e-backup e2e-access e2e-dashboard e2e-chaos e2e-matrix
e2e: ## All chainsaw + Go e2e on current cluster (stub)
e2e-smoke: ## < 5 min subset: create, connect, scale, delete (stub)
e2e-ha: ## Switchover, failover, pinning, rolling update (stub)
e2e-backup: ## Archiving, full/delta, schedules, retention, PITR (stub)
e2e-access: ## Roles, databases, grants, HBA, TLS (stub)
e2e-dashboard: ## API-level dashboard tests + Playwright smoke (stub)
e2e-chaos: ## Ledger harness under Chaos Mesh faults (stub)
e2e-matrix: ## Loop KIND_K8S_VERSION x PG_VERSIONS (stub)
e2e e2e-smoke e2e-ha e2e-backup e2e-access e2e-dashboard e2e-chaos e2e-matrix:
	@echo "$@: not yet implemented"

.PHONY: accept-p0
accept-p0: ## Acceptance suite for phase 0 (creates and deletes local clusters)
	hack/accept/p0.sh

# print-VAR prints a make variable, for scripts.
print-%:
	@echo '$($*)'

.PHONY: clean
clean: ## Remove ./bin, _artifacts, build outputs
	rm -rf "$(LOCALBIN)" _artifacts

##@ Dependencies

LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p "$(LOCALBIN)"

# Versions verified 2026-10-19 (08 §2).
CONTROLLER_TOOLS_VERSION ?= v0.23.0
ENVTEST_K8S_VERSION ?= 1.36.2
GOLANGCI_LINT_VERSION ?= v2.15.0
KUSTOMIZE_VERSION ?= v5.8.3
KIND_VERSION ?= v0.33.0
K3D_VERSION ?= v5.9.0
KUBECTL_VERSION ?= v1.37.1
K3S_IMAGE ?= rancher/k3s:v1.36.5-k3s1@sha256:057cfd5a9d51b89f1f0ee139c28d5d5fdd5aa7ddeac2742a0ba90c6dbc0329bb
REGISTRY_IMAGE ?= registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
# Node images published with kind v0.33.0.
KIND_NODE_IMAGE_1.34 := kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d
KIND_NODE_IMAGE_1.35 := kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0
KIND_NODE_IMAGE_1.36 := kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
KIND_NODE_IMAGE_1.37 := kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
KIND_NODE_IMAGE ?= $(or $(KIND_NODE_IMAGE_$(KIND_K8S_VERSION)),$(error no kind node image for KIND_K8S_VERSION=$(KIND_K8S_VERSION)))
# WAL-G v3.0.9 (lightweight tag) = commit below.
WALG_VERSION ?= v3.0.9
WALG_COMMIT ?= 3e493188db28335fb93a45bd680c6ff8fc3028c1
# setup-envtest follows the controller-runtime version in go.mod.
ENVTEST_VERSION ?= $(shell go list -m -f '{{.Version}}' sigs.k8s.io/controller-runtime)

CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint
KUSTOMIZE ?= $(LOCALBIN)/kustomize
KIND ?= $(LOCALBIN)/kind
K3D ?= $(LOCALBIN)/k3d
KUBECTL ?= $(LOCALBIN)/kubectl

.PHONY: controller-gen
controller-gen: $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: setup-envtest
setup-envtest: $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: golangci-lint
golangci-lint: $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/v2/cmd/golangci-lint,$(GOLANGCI_LINT_VERSION))

.PHONY: kustomize
kustomize: $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: kind
kind: $(LOCALBIN)
	$(call go-install-tool,$(KIND),sigs.k8s.io/kind,$(KIND_VERSION))

.PHONY: k3d
k3d: $(LOCALBIN)
	$(call go-install-tool,$(K3D),github.com/k3d-io/k3d/v5,$(K3D_VERSION))

.PHONY: kubectl
kubectl: $(LOCALBIN)
	@[ -f "$(KUBECTL)-$(KUBECTL_VERSION)" ] && [ "$$(readlink -- "$(KUBECTL)")" = "$(KUBECTL)-$(KUBECTL_VERSION)" ] || { \
		url="https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/$$(go env GOHOSTOS)/$$(go env GOHOSTARCH)/kubectl"; \
		echo "Installing kubectl $(KUBECTL_VERSION)"; \
		curl -fsSL -o "$(KUBECTL)-$(KUBECTL_VERSION).tmp" "$$url"; \
		echo "$$(curl -fsSL "$$url.sha256")  $(KUBECTL)-$(KUBECTL_VERSION).tmp" | shasum -a 256 -c - >/dev/null; \
		chmod +x "$(KUBECTL)-$(KUBECTL_VERSION).tmp"; \
		mv "$(KUBECTL)-$(KUBECTL_VERSION).tmp" "$(KUBECTL)-$(KUBECTL_VERSION)"; \
		ln -sf "$(KUBECTL)-$(KUBECTL_VERSION)" "$(KUBECTL)"; \
	}

# go-install-tool installs package $(2) at version $(3) as $(1)-$(3) and points
# the symlink $(1) at it; a no-op when that version is already installed.
define go-install-tool
@[ -f "$(1)-$(3)" ] && [ "$$(readlink -- "$(1)" 2>/dev/null)" = "$(1)-$(3)" ] || { \
	echo "Installing $(2)@$(3)"; \
	rm -f "$(1)"; \
	GOBIN="$(LOCALBIN)" go install "$(2)@$(3)"; \
	mv "$(LOCALBIN)/$$(basename "$(1)")" "$(1)-$(3)"; \
	ln -sf "$(1)-$(3)" "$(1)"; \
}
endef

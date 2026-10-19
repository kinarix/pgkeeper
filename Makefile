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

##@ General

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: tools
tools: controller-gen setup-envtest golangci-lint kustomize ## Install all pinned tools into ./bin

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
docker-build: docker-build-tools ## Build images: tools (instance + wal-g)

TOOLS_CONTEXT = $(LOCALBIN)/image-tools-linux-$(GOARCH)

.PHONY: docker-build-tools
docker-build-tools: build-walg
	rm -rf "$(TOOLS_CONTEXT)" && mkdir -p "$(TOOLS_CONTEXT)/LICENSES"
	CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -trimpath -o "$(TOOLS_CONTEXT)/pgkeeper-instance" ./cmd/instance
	cp "$(WALG)" "$(TOOLS_CONTEXT)/wal-g"
	hack/collect-licenses.sh "$(TOOLS_CONTEXT)/LICENSES/pgkeeper-instance" . ./cmd/instance GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0
	hack/collect-licenses.sh "$(TOOLS_CONTEXT)/LICENSES/wal-g" "$$(cd "$${TMPDIR:-/tmp}" && go mod download -json github.com/wal-g/wal-g@$(WALG_COMMIT) | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$$/\1/p')" ./main/pg GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0 GOEXPERIMENT=jsonv2
	docker build --platform linux/$(GOARCH) -f images/tools/Dockerfile -t "$(TOOLS_IMG)" "$(TOOLS_CONTEXT)"

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
# WAL-G v3.0.9 (lightweight tag) = commit below.
WALG_VERSION ?= v3.0.9
WALG_COMMIT ?= 3e493188db28335fb93a45bd680c6ff8fc3028c1
# setup-envtest follows the controller-runtime version in go.mod.
ENVTEST_VERSION ?= $(shell go list -m -f '{{.Version}}' sigs.k8s.io/controller-runtime)

CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint
KUSTOMIZE ?= $(LOCALBIN)/kustomize

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

# =============================================================================
# AI Engineering DevBox
# =============================================================================
# `make` with no target prints this help. Every target is a thin wrapper over a
# command you could type yourself — nothing here hides what it runs.
#
# Podman is the default runtime. Set ENGINE=docker to use Docker instead; the
# Containerfiles are plain OCI and require neither BuildKit nor Docker Desktop.
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.ONESHELL:

ENGINE        ?= podman
BASE_IMAGE    ?= ai-devbox-base
DEVBOX_IMAGE  ?= ai-devbox
TAG           ?= latest
REGISTRY      ?=

VCS_REF       := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE    := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
VERSION       ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

# Optional build modules. Enable what you use:
#   make build FEATURE_CLOUD_AWS=1 FEATURE_CLOUD_AZURE=1
FEATURE_CLOUD_AWS      ?= 0
FEATURE_CLOUD_AZURE    ?= 0
FEATURE_CLOUD_GCP      ?= 0
FEATURE_K8S_LOCAL      ?= 0
FEATURE_AI_GEMINI      ?= 1
FEATURE_AI_EXTRA       ?= 0
FEATURE_MCP_BROWSER    ?= 0
FEATURE_MCP_KUBERNETES ?= 0
FEATURE_ANSIBLE        ?= 0

BASE_REF   := $(if $(REGISTRY),$(REGISTRY)/,)$(BASE_IMAGE):$(TAG)
DEVBOX_REF := $(if $(REGISTRY),$(REGISTRY)/,)$(DEVBOX_IMAGE):$(TAG)

COMMON_ARGS := \
	--build-arg VCS_REF=$(VCS_REF) \
	--build-arg BUILD_DATE=$(BUILD_DATE) \
	--build-arg VERSION=$(VERSION)

FEATURE_ARGS := \
	--build-arg FEATURE_CLOUD_AWS=$(FEATURE_CLOUD_AWS) \
	--build-arg FEATURE_CLOUD_AZURE=$(FEATURE_CLOUD_AZURE) \
	--build-arg FEATURE_CLOUD_GCP=$(FEATURE_CLOUD_GCP) \
	--build-arg FEATURE_K8S_LOCAL=$(FEATURE_K8S_LOCAL) \
	--build-arg FEATURE_AI_GEMINI=$(FEATURE_AI_GEMINI) \
	--build-arg FEATURE_AI_EXTRA=$(FEATURE_AI_EXTRA) \
	--build-arg FEATURE_MCP_BROWSER=$(FEATURE_MCP_BROWSER) \
	--build-arg FEATURE_MCP_KUBERNETES=$(FEATURE_MCP_KUBERNETES) \
	--build-arg FEATURE_ANSIBLE=$(FEATURE_ANSIBLE)

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  AI Engineering DevBox — $(VERSION) ($(VCS_REF))"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  engine=$(ENGINE)  base=$(BASE_REF)  devbox=$(DEVBOX_REF)"
	@echo ""

# --------------------------------------------------------------------- build --
.PHONY: build
build: build-base build-devbox ## Build both images

.PHONY: build-base
build-base: ## Build the base image (OS + language runtimes)
	$(ENGINE) build -f Containerfile.base -t $(BASE_REF) $(COMMON_ARGS) .

.PHONY: build-devbox
build-devbox: ## Build the DevBox image (needs the base image)
	$(ENGINE) build -f Containerfile -t $(DEVBOX_REF) \
	  --build-arg BASE_IMAGE_REF=$(BASE_REF) $(COMMON_ARGS) $(FEATURE_ARGS) .

.PHONY: rebuild
rebuild: ## Rebuild the DevBox image only (the common case)
	$(MAKE) build-devbox

.PHONY: build-all-clouds
build-all-clouds: ## Build with every cloud CLI enabled (large image)
	$(MAKE) build-devbox FEATURE_CLOUD_AWS=1 FEATURE_CLOUD_AZURE=1 FEATURE_CLOUD_GCP=1

# ----------------------------------------------------------------------- run --
.PHONY: up
up: ## Start the DevBox with compose
	$(ENGINE) compose up -d devbox

.PHONY: up-full
up-full: ## Start the DevBox + model router + local model runtime
	$(ENGINE) compose --profile full up -d

.PHONY: down
down: ## Stop the stack (volumes are kept)
	$(ENGINE) compose down

.PHONY: shell
shell: ## Open a shell in the running DevBox
	$(ENGINE) exec -it ai-devbox bash -l

.PHONY: run
run: ## Run a throwaway DevBox with the current directory mounted
	$(ENGINE) run --rm -it \
	  --userns=keep-id \
	  --security-opt no-new-privileges \
	  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE \
	  -v "$(PWD)":/workspace:z \
	  -e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e GEMINI_API_KEY \
	  -e GITHUB_PERSONAL_ACCESS_TOKEN \
	  $(DEVBOX_REF) bash -l

.PHONY: doctor
doctor: ## Run `devbox doctor` inside a throwaway container
	$(ENGINE) run --rm $(DEVBOX_REF) devbox doctor

# ---------------------------------------------------------------------- test --
.PHONY: test
test: lint test-image ## Run every check

.PHONY: lint
lint: ## Lint this repository (shell, YAML, workflows)
	@echo "── shellcheck ──"
	@shellcheck -x -S warning $$(find bin scripts tests -type f \( -name '*.sh' -o -name devbox -o -name ai -o -name mcp \) 2>/dev/null) || exit 1
	@echo "── yamllint ──"
	@yamllint -c config/tools/yamllint.yaml . || exit 1
	@echo "── actionlint ──"
	@actionlint || exit 1
	@echo "all lint checks passed"

.PHONY: test-image
test-image: ## Run the image test suite against $(DEVBOX_REF)
	ENGINE=$(ENGINE) IMAGE=$(DEVBOX_REF) BASE_IMAGE=$(BASE_REF) tests/run.sh

.PHONY: validate
validate: ## Validate configuration files without building
	tests/validate-config.sh

# ------------------------------------------------------------------ security --
.PHONY: scan
scan: ## Scan the built image for vulnerabilities
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(DEVBOX_REF)

.PHONY: sbom
sbom: ## Generate an SBOM for the built image
	@mkdir -p sbom
	syft scan $(DEVBOX_REF) -o spdx-json=sbom/devbox.spdx.json -o cyclonedx-json=sbom/devbox.cdx.json
	@echo "wrote sbom/devbox.{spdx,cdx}.json"

.PHONY: sign
sign: ## Sign the image with cosign (keyless OIDC)
	COSIGN_EXPERIMENTAL=1 cosign sign --yes $(DEVBOX_REF)

# --------------------------------------------------------------------- utils --
.PHONY: sync
sync: ## Regenerate AI instruction files from the canonical policy
	scripts/configure/render-ai-rules.sh

.PHONY: sync-check
sync-check: ## Fail if generated AI instruction files are stale
	scripts/configure/render-ai-rules.sh --check

.PHONY: versions
versions: ## Print the pinned version manifest
	@scripts/lib/versions.sh | sed 's/^export V_/  /;s/=/ = /'

.PHONY: push
push: ## Push both images to $(REGISTRY)
	@test -n "$(REGISTRY)" || { echo "REGISTRY is not set"; exit 1; }
	$(ENGINE) push $(BASE_REF)
	$(ENGINE) push $(DEVBOX_REF)

.PHONY: clean
clean: ## Remove built images (volumes are kept)
	-$(ENGINE) rmi $(DEVBOX_REF) $(BASE_REF)

.PHONY: clean-all
clean-all: ## Remove images AND volumes — this deletes persisted developer state
	@read -p "This deletes all DevBox volumes (caches, config, history). Continue? [y/N] " r; \
	 [ "$$r" = y ] || exit 1
	-$(ENGINE) compose down -v
	-$(ENGINE) rmi $(DEVBOX_REF) $(BASE_REF)

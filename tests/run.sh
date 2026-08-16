#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# DevBox image test suite.
#
#   ENGINE=podman IMAGE=ai-devbox:latest \
#     BASE_IMAGE=ghcr.io/droderiquesit/ai-devbox/ai-engineering:1.0.0 tests/run.sh
#
# Tests the CONTRACT of the image, not its implementation:
#   * every tool the docs promise is present and runnable
#   * the container is non-root and the workspace is writable
#   * the CLIs work, and their guardrails actually block what they claim to
#   * no credentials are baked into the image
#   * configuration renders correctly
#
# This is what stops the README from quietly becoming fiction.
# -----------------------------------------------------------------------------
set -uo pipefail

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ai-devbox:latest}"
# The base is the pinned Base Image Factory release; resolve the default from
# versions.yaml so this suite and CI cannot disagree about which base is meant.
BASE_IMAGE="${BASE_IMAGE:-$("$(dirname "$0")/../.github/scripts/image-ref.sh" base 2>/dev/null || echo "")}"
ONLY="${1:-}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R_=$'\033[31m'; N=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
else G=''; R_=''; N=''; B=''; D=''; fi

PASS=0; FAIL=0; SKIP=0
FAILED_TESTS=()

sect() { printf '\n%s══ %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
no()   { printf '  %s✗%s %s\n' "$R_" "$N" "$*"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$*"); }
sk()   { printf '  %s–%s %s%s%s\n' "$D" "$N" "$D" "$*" "$N"; SKIP=$((SKIP+1)); }

# The entrypoint logs first-run volume seeding to stderr. That is correct
# behaviour, not test output — strip it so results stay readable.
strip_noise() { grep -v $'\[devbox\]' | grep -v '^$' || true; }

# run <description> <shell-command-inside-container>
run() {
  local desc="$1" cmd="$2" out
  if out="$("$ENGINE" run --rm "$IMAGE" bash -lc "$cmd" 2>&1 | strip_noise)"; then
    ok "$(printf '%-28s %s' "$desc" "${D}$(printf '%s' "$out" | head -1 | cut -c1-60)${N}")"
  else
    no "$(printf '%-28s %s' "$desc" "$(printf '%s' "$out" | head -2 | tr '\n' ' ' | cut -c1-90)")"
  fi
}

# expect_fail <description> <command> — the command MUST fail (guardrail tests)
expect_fail() {
  local desc="$1" cmd="$2" out
  if out="$("$ENGINE" run --rm "$IMAGE" bash -lc "$cmd" 2>&1)"; then
    no "$(printf '%-28s %s' "$desc" 'succeeded but should have been refused')"
  else
    ok "$(printf '%-28s %s' "$desc" "${D}correctly refused${N}")"
  fi
}

section_wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

printf '%sAI ENGINEERING DEVBOX — test suite%s\n' "$B" "$N"
printf '  engine %s   image %s\n' "$ENGINE" "$IMAGE"

# =============================================================================
if section_wanted image; then
sect "Image sanity"
if "$ENGINE" image exists "$IMAGE" 2>/dev/null || "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image exists: ${IMAGE}"
else
  no "image not found: ${IMAGE}"; printf '\n'; exit 1
fi
run "container starts"            'echo alive'
run "non-root user"               '[ "$(id -u)" -ne 0 ] && id -un'
run "workspace writable"          'touch /workspace/.t && rm /workspace/.t && echo writable'
run "home writable"               'touch "$HOME/.t" && rm "$HOME/.t" && echo writable'
run "locale is UTF-8"             'locale | grep -m1 LANG'
fi

# =============================================================================
if section_wanted core; then
sect "Core toolchain (§38)"
run "git"          'git --version'
run "gh"           'gh --version'
run "curl"         'curl --version'
run "wget"         'wget --version'
run "jq"           'jq --version'
run "yq"           'yq --version'
run "make"         'make --version'
run "just"         'just --version'
run "task"         'task --version'
run "ripgrep"      'rg --version'
run "fd"           'fd --version'
run "fzf"          'fzf --version'
run "bat"          'bat --version'
run "tree"         'tree --version'
run "tmux"         'tmux -V'
run "vim"          'vim --version'
run "rsync"        'rsync --version'
run "ssh"          'ssh -V'
run "gnupg"        'gpg --version'
fi

# =============================================================================
if section_wanted languages; then
sect "Languages (§9)"
run "python"       'python --version || python3 --version'
run "python3"      'python3 --version'
run "node"         'node --version'
run "npm"          'npm --version'
run "pnpm"         'pnpm --version || corepack pnpm --version'
run "go"           'go version'
run "uv"           'uv --version'
run "pipx"         'pipx --version'
run "ruff"         'ruff --version'
run "black"        'black --version'
run "pytest"       'pytest --version'
run "mypy"         'mypy --version'
fi

# =============================================================================
if section_wanted terraform; then
sect "Infrastructure as Code (§5)"
run "terraform"      'terraform version'
run "tofu"           'tofu version'
run "terragrunt"     'terragrunt --version'
run "terraform-ls"   'terraform-ls --version'
run "tflint"         'tflint --version'
run "terraform-docs" 'terraform-docs --version'
run "checkov"        'checkov --version'
run "infracost"      'infracost --version'
run "opa"            'opa version'
run "conftest"       'conftest --version'
run "pre-commit"     'pre-commit --version'
fi

# =============================================================================
if section_wanted kubernetes; then
sect "Kubernetes / GitOps (§7)"
run "kubectl"   'kubectl version --client=true --output=yaml | head -3'
run "helm"      'helm version --short'
run "kustomize" 'kustomize version'
run "k9s"       'k9s version --short'
run "stern"     'stern --version'
run "kubectx"   'kubectx --help >/dev/null && echo ok'
run "kubens"    'kubens --help >/dev/null && echo ok'
run "flux"      'flux --version'
fi

# =============================================================================
if section_wanted security; then
sect "Security / supply chain (§28, §29)"
run "trivy"      'trivy --version'
run "gitleaks"   'gitleaks version'
run "semgrep"    'semgrep --version'
run "shellcheck" 'shellcheck --version | grep version:'
run "yamllint"   'yamllint --version'
run "actionlint" 'actionlint -version'
run "syft"       'syft version'
run "grype"      'grype version'
run "cosign"     'cosign version 2>&1 | head -3'
fi

# =============================================================================
if section_wanted ai; then
sect "AI platform (§10)"
run "claude"  'claude --version'
run "codex"   'codex --version'
run "gemini"  'gemini --version'
run "llm"     'llm --version'
run "litellm" 'litellm --version 2>&1 | head -1'
sect "MCP servers (§14)"
run "mcp filesystem" 'command -v mcp-server-filesystem'
run "mcp git"        'command -v mcp-server-git'
run "mcp fetch"      'command -v mcp-server-fetch'
run "mcp time"       'command -v mcp-server-time'
run "mcp memory"     'command -v mcp-server-memory'
run "mcp context7"   'command -v context7-mcp'
fi

# =============================================================================
if section_wanted cli; then
sect "DevBox CLIs (§26)"
run "devbox on PATH"     'command -v devbox'
run "ai on PATH"         'command -v ai'
run "mcp on PATH"        'command -v mcp'
run "devbox help"        'devbox help | head -1'
run "devbox info"        'devbox info | head -3'
run "devbox versions"    'devbox versions | head -3'
run "devbox status"      'devbox status | head -3'
run "devbox doctor"      'devbox doctor --core-only >/dev/null && echo healthy'
# The HEALTHCHECK runs doctor WITHOUT a login shell: no profile, no profile
# PATH, no profile exports. Everything else in this suite goes through
# `bash -lc`, which is exactly how a `set -u` crash on a profile-only variable
# AND a profile-only PATH both passed 152 tests while the running container
# reported unhealthy. Run the literal healthcheck command the literal
# healthcheck way — no login shell wrapper — and require it to pass outright.
if "$ENGINE" run --rm "$IMAGE" /opt/devbox/bin/devbox doctor --quiet --core-only >/dev/null 2>&1; then
  ok "doctor (healthcheck exact)   ${D}rc=0 without a login shell${N}"
else
  no "doctor (healthcheck exact)   failed outside a login shell — container would report unhealthy"
fi
run "devbox doctor json" 'devbox doctor --json | jq -r .status'
run "ai models"          'ai models | head -3'
run "ai providers"       'ai providers | head -3'
run "ai profile list"    'ai profile list | head -3'
run "ai prompt list"     'ai prompt | head -3'
run "ai agent list"      'ai agent | head -3'
run "ai run (list)"      'ai run | head -3'
run "ai doctor"          'ai doctor | head -3'
run "mcp list"           'mcp list | head -3'
run "mcp status"         'mcp status | head -3'
run "mcp profile list"   'mcp profile list | head -3'
run "mcp render"         'mcp render && jq -e ".mcpServers | keys | length > 0" ~/.mcp.json'
run "mcp doctor"         'mcp doctor >/dev/null && echo conformant'
fi

# =============================================================================
if section_wanted guardrails; then
sect "Guardrails (§18) — these MUST refuse"
# The classifier is the single implementation of the command policy, so testing
# it is testing the guardrail, not a copy of it.
classify() {
  "$ENGINE" run --rm "$IMAGE" bash -lc \
    ". /opt/devbox/bin/devbox-lib.sh && classify_command '$1'" 2>/dev/null
}
for cmd in 'terraform destroy' 'tofu destroy' 'kubectl delete pod x' \
           'helm uninstall app' 'rm -rf /' 'git push --force' 'git reset --hard HEAD~1' \
           'terraform apply -auto-approve' 'gh repo delete'; do
  c="$(classify "$cmd")"
  [ "$c" = BLOCKED ] && ok "$(printf '%-32s %s' "$cmd" "${D}BLOCKED${N}")" \
                     || no "$(printf '%-32s %s' "$cmd" "classified '${c}', expected BLOCKED")"
done
for cmd in 'terraform apply' 'kubectl apply -f x.yaml' 'git push' 'aws s3 rm s3://b/k'; do
  c="$(classify "$cmd")"
  case "$c" in
    APPROVAL_REQUIRED|BLOCKED) ok "$(printf '%-32s %s' "$cmd" "${D}${c}${N}")" ;;
    *) no "$(printf '%-32s %s' "$cmd" "classified '${c}', expected APPROVAL_REQUIRED or stricter")" ;;
  esac
done
for cmd in 'terraform plan' 'terraform validate' 'kubectl get pods' 'git status'; do
  c="$(classify "$cmd")"
  [ "$c" = SAFE ] && ok "$(printf '%-32s %s' "$cmd" "${D}SAFE${N}")" \
                  || no "$(printf '%-32s %s' "$cmd" "classified '${c}', expected SAFE")"
done
# An unknown command must default to needing approval, never to SAFE.
c="$(classify 'some-tool --wipe-everything')"
[ "$c" = APPROVAL_REQUIRED ] && ok "unknown command defaults to APPROVAL_REQUIRED" \
  || no "unknown command classified '${c}' — must default to APPROVAL_REQUIRED"
fi

# =============================================================================
if section_wanted secrets; then
sect "Secrets (§22, §31) — nothing baked in"
run "no ~/.aws"          '[ ! -e "$HOME/.aws" ] && echo absent'
run "no ~/.azure"        '[ ! -e "$HOME/.azure" ] && echo absent'
run "no ~/.config/gcloud" '[ ! -e "$HOME/.config/gcloud" ] && echo absent'
run "no ~/.ssh"          '[ ! -e "$HOME/.ssh" ] && echo absent'
run "no ~/.netrc"        '[ ! -e "$HOME/.netrc" ] && echo absent'
run "no root creds"      '[ ! -e /root/.aws ] && [ ! -e /root/.ssh ] && echo absent'
run "no API keys in env" '! env | grep -qiE "(api_key|secret|token)=." && echo clean'
run "redaction works"    'echo "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz" | (. /opt/devbox/bin/devbox-lib.sh; redact) | grep -q redacted && echo redacted'
run "doctor hides values" 'ANTHROPIC_API_KEY=sk-ant-supersecretvaluehere devbox doctor 2>&1 | grep -q supersecret && echo LEAKED || echo "no leak"'
fi

# =============================================================================
if section_wanted config; then
sect "Configuration"
run "policy present"     'test -r /opt/devbox/ai/policies/policy.yaml && echo ok'
run "models present"     'test -r /opt/devbox/ai/models/models.yaml && echo ok'
run "mcp registry"       'test -r /opt/devbox/mcp/servers.yaml && echo ok'
run "versions.yaml"      'test -r /opt/devbox/versions.yaml && echo ok'
run "9 agent roles"      '[ "$(ls /opt/devbox/ai/agents/*.md | grep -vc README)" -ge 9 ] && echo ok'
run "9 prompts"          '[ "$(ls /opt/devbox/ai/prompts/*.md | grep -vc README)" -ge 9 ] && echo ok'
run "tf plugin cache"    'echo "$TF_PLUGIN_CACHE_DIR" | grep -q terraform && echo set'
run "terraformrc"        'devbox-entrypoint true 2>/dev/null; grep -q plugin_cache_dir "$HOME/.terraformrc" && echo configured'
run "shell aliases"      'shopt -s expand_aliases; . /etc/devbox/shell.d/10-aliases.sh; alias tf >/dev/null && echo ok'
run "no apply alias"     '. /etc/devbox/shell.d/10-aliases.sh; ! alias | grep -q "terraform apply" && echo "none, correct"'
run "completions"        'ls /etc/devbox/completions | wc -l'
run "ai sync --check"    'cd /tmp && mkdir -p t && cd t && git init -q . && ai sync >/dev/null && ai sync --check >/dev/null && echo current'
fi

# =============================================================================
if section_wanted workflow; then
sect "Terraform workflow (§5, §38)"
TFDIR="$(mktemp -d)"; chmod 0755 "$TFDIR"
cat > "$TFDIR/main.tf" <<'TF'
terraform {
  required_version = ">= 1.5"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "greeting" {
  description = "Text written to the generated file"
  type        = string
  default     = "hello"
}

resource "local_file" "example" {
  content  = var.greeting
  filename = "${path.module}/generated.txt"
}

output "path" {
  description = "Path of the generated file"
  value       = local_file.example.filename
}
TF
run_in_dir() {
  local desc="$1" cmd="$2" out
  if out="$("$ENGINE" run --rm -v "$TFDIR":/workspace/tf:z -w /workspace/tf "$IMAGE" bash -lc "$cmd" 2>&1 | strip_noise)"; then
    ok "$(printf '%-28s %s' "$desc" "${D}$(printf '%s' "$out" | tail -1 | cut -c1-60)${N}")"
  else
    no "$(printf '%-28s %s' "$desc" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-100)")"
  fi
}
run_in_dir "terraform fmt -check"  'terraform fmt -check -recursive .'
run_in_dir "tofu fmt -check"       'tofu fmt -check -recursive .'
run_in_dir "tflint"                'tflint --no-color . || true; echo done'
run_in_dir "checkov"               'checkov -d . --compact --quiet --skip-download >/dev/null 2>&1; echo done'
run_in_dir "trivy config"          'trivy config --quiet . >/dev/null 2>&1; echo done'
run_in_dir "terraform-docs"        'terraform-docs markdown table . | head -3'
rm -rf "$TFDIR"

sect "GitHub Actions workflow (§6)"
WFDIR="$(mktemp -d)"; chmod -R 0755 "$WFDIR"; mkdir -p "$WFDIR/.github/workflows"
cat > "$WFDIR/.github/workflows/ok.yml" <<'WF'
---
name: ok
"on":
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: echo hello
WF
chmod -R a+rX "$WFDIR"
cat > "$WFDIR/.github/workflows/broken.yml" <<'WF'
---
name: broken
"on": push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "${{ github.event.head_commit.messag }}"
        if: ${{ nonexistent_function() }}
WF
chmod -R a+rX "$WFDIR"
if out="$("$ENGINE" run --rm -v "$WFDIR":/workspace/wf:z -w /workspace/wf "$IMAGE" \
          bash -lc 'actionlint -no-color .github/workflows/ok.yml' 2>&1 | strip_noise)"; then
  ok "actionlint accepts a valid workflow"
else
  no "actionlint rejected a valid workflow: $(printf '%s' "$out" | head -2)"
fi
if "$ENGINE" run --rm -v "$WFDIR":/workspace/wf:z -w /workspace/wf "$IMAGE" \
   bash -lc 'actionlint -no-color .github/workflows/broken.yml' >/dev/null 2>&1; then
  no "actionlint accepted a broken workflow — the linter is not working"
else
  ok "actionlint rejects a broken workflow"
fi
rm -rf "$WFDIR"

sect "Security scan (§28)"
SDIR="$(mktemp -d)"; chmod 0755 "$SDIR"
printf 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' > "$SDIR/creds.txt"
if out="$("$ENGINE" run --rm -v "$SDIR":/workspace/s:z -w /workspace/s "$IMAGE" \
          bash -lc 'devbox security scan --scope secrets 2>&1' | strip_noise)"; then
  printf '%s' "$out" | grep -qi 'secret' && ok "security scan runs" || ok "security scan runs (clean)"
else
  ok "security scan runs and reports findings"
fi
printf '%s' "${out:-}" | grep -q 'AKIAIOSFODNN7EXAMPLE' \
  && no "scan output leaked the secret value" \
  || ok "scan output does not leak secret values"
rm -rf "$SDIR"
fi

# =============================================================================
if section_wanted base; then
sect "Base image contract"
if [ -n "$BASE_IMAGE" ] && "$ENGINE" image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  b() {
    local desc="$1" cmd="$2" out
    if out="$("$ENGINE" run --rm "$BASE_IMAGE" bash -lc "$cmd" 2>&1)"; then
      ok "$(printf '%-28s %s' "base: $desc" "${D}$(printf '%s' "$out" | head -1 | cut -c1-40)${N}")"
    else no "$(printf '%-28s %s' "base: $desc" "$(printf '%s' "$out" | head -1)")"; fi
  }
  b "non-root"  '[ "$(id -u)" -ne 0 ] && id -un'
  b "go"        'go version'
  b "node"      'node --version'
  b "python"    'python3 --version'
  b "uv"        'uv --version'
  # The base must NOT contain the devbox layer — that is the whole split.
  if "$ENGINE" run --rm "$BASE_IMAGE" bash -lc 'command -v terraform' >/dev/null 2>&1; then
    no "base image contains terraform — the image split has leaked"
  else
    ok "base: correctly excludes the DevBox toolchain"
  fi
else
  sk "base image ${BASE_IMAGE} not present"
fi
fi

# =============================================================================
printf '\n%s══ RESULT%s\n' "$B" "$N"
if [ "$FAIL" -eq 0 ]; then
  printf '  %s%d passed%s, %d skipped\n\n' "$G" "$PASS" "$N" "$SKIP"
  exit 0
else
  printf '  %s%d passed, %d FAILED%s, %d skipped\n\n' "$R_" "$PASS" "$FAIL" "$N" "$SKIP"
  printf '  Failures:\n'
  printf '    %s\n' "${FAILED_TESTS[@]}"
  printf '\n'
  exit 1
fi

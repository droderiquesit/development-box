#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lint.sh — the repository lint checks, ONE definition for CI and local use.
#
#   lint.sh [all|shellcheck|shfmt|yamllint|actionlint|markdownlint]...
#
# ci.yml's lint jobs, `make lint` and `task lint` all call this script, so the
# file sets, flags and configs cannot drift apart. CI installs the tools and
# then runs one check per job; locally `all` runs every check.
#
# The untracked workspace/ directory (the default host bind mount for
# /workspace, usually holding other clones) is excluded everywhere — it is
# never part of this repository and absent in CI.
#
# A tool that is not installed is a hard failure when LINT_STRICT=1 (CI sets
# it). Locally it is a warning, because not every tool ships in the image
# (shfmt, markdownlint) — CI still enforces those.
# -----------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../.."

STRICT="${LINT_STRICT:-0}"
failed=0

have() { # have <tool> — false (and warn, or fail when strict) if missing
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "$STRICT" = 1 ]; then
    echo "::error::$1 is not installed" >&2
    failed=1
  else
    echo "warning: $1 not installed — skipped locally (CI enforces it)" >&2
  fi
  return 1
}

shell_files() {
  find bin scripts tests .github/scripts infra -type f \
    \( -name '*.sh' -o -name devbox -o -name ai -o -name mcp \) 2>/dev/null
}

yaml_files() {
  find . \( -path ./.git -o -path ./workspace -o -name node_modules \
    -o -name .terraform -o -name .venv \) -prune -o \
    -type f \( -name '*.yml' -o -name '*.yaml' \) -print
}

run_shellcheck() {
  echo "── shellcheck ──"
  have shellcheck || return 0
  local files
  mapfile -t files < <(shell_files)
  printf 'checking %d files\n' "${#files[@]}"
  shellcheck -x -S warning "${files[@]}" || failed=1
}

run_shfmt() {
  echo "── shfmt ──"
  have shfmt || return 0
  shfmt -d -i 2 -ci bin scripts config/shell || {
    echo "::error::shell formatting differs — run: shfmt -w -i 2 -ci bin scripts config/shell"
    failed=1
  }
}

run_yamllint() {
  echo "── yamllint ──"
  have yamllint || return 0
  local files
  mapfile -t files < <(yaml_files)
  yamllint -c config/tools/yamllint.yaml "${files[@]}" || failed=1
}

run_actionlint() {
  echo "── actionlint ──"
  have actionlint || return 0
  actionlint -color || failed=1
}

run_markdownlint() {
  echo "── markdownlint ──"
  # The pinned CLI from .github/tooling (npm ci --prefix .github/tooling);
  # fall back to one on PATH. Rules come from .markdownlint.json either way.
  local bin=.github/tooling/node_modules/.bin/markdownlint
  if [ ! -x "$bin" ]; then
    if have markdownlint; then
      bin=markdownlint
    else
      [ "$STRICT" = 1 ] || echo "  hint: npm ci --prefix .github/tooling --no-audit --no-fund" >&2
      return 0
    fi
  fi
  "$bin" '**/*.md' --ignore node_modules --ignore .github/tooling \
    --ignore workspace || failed=1
}

[ "$#" -gt 0 ] || set -- all
for check in "$@"; do
  case "$check" in
    all)
      run_shellcheck
      run_shfmt
      run_yamllint
      run_actionlint
      run_markdownlint
      ;;
    shellcheck | shfmt | yamllint | actionlint | markdownlint) "run_${check}" ;;
    *)
      echo "usage: lint.sh [all|shellcheck|shfmt|yamllint|actionlint|markdownlint]..." >&2
      exit 2
      ;;
  esac
done

if [ "$failed" -ne 0 ]; then
  echo "lint failed" >&2
  exit 1
fi
echo "lint checks passed"

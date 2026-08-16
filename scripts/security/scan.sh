#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# devbox security scan — a local security review of the repository.
#
#   devbox security scan
#   devbox security scan --scope terraform|secrets|deps|containers|code|all
#   devbox security scan --format json
#   devbox security scan --fail-on critical|high|medium
#
# Design: run each tool where it is genuinely best, once. No tool is run twice
# for the same class of finding — see docs/decisions.md for which scanner owns
# which surface and why the obvious duplicates were rejected.
# -----------------------------------------------------------------------------
set -uo pipefail
# shellcheck source=../../bin/devbox-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../bin/devbox-lib.sh"

SCOPE=all
FORMAT=text
FAIL_ON=none
TARGET="."

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)   SCOPE="$2"; shift 2 ;;
    --format)  FORMAT="$2"; shift 2 ;;
    --fail-on) FAIL_ON="$2"; shift 2 ;;
    --path)    TARGET="$2"; shift 2 ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

ROOT="$(cd "$TARGET" 2>/dev/null && pwd)" || abort "no such path: $TARGET"
OUT_DIR="${DEVBOX_STATE}/scan"
install -d -m 0700 "$OUT_DIR"
FINDINGS=0
SECTIONS=()

want() { [ "$SCOPE" = all ] || [ "$SCOPE" = "$1" ]; }

record() { SECTIONS+=("$1|$2|$3"); }   # tool | status | detail

# ---------------------------------------------------------------- secrets ----
scan_secrets() {
  want secrets || return 0
  head2 "Secrets — gitleaks (working tree + full git history)"
  if ! have gitleaks; then record gitleaks skipped "not installed"; skip "gitleaks not installed"; return 0; fi
  local report="${OUT_DIR}/gitleaks.json"
  local -a cfg=()
  [ -r "${ROOT}/.gitleaks.toml" ] && cfg=(--config="${ROOT}/.gitleaks.toml")
  # gitleaks exits non-zero when it finds anything; that is expected, so the
  # report itself — not the exit code — is what we act on.
  if in_git_repo; then
    # `git` mode walks history: a secret that was committed and then removed is
    # still compromised, and is exactly the one people forget about.
    gitleaks git "$ROOT" --report-format json --report-path "$report" --redact "${cfg[@]}" >/dev/null 2>&1 || true
  else
    gitleaks dir "$ROOT" --report-format json --report-path "$report" --redact "${cfg[@]}" >/dev/null 2>&1 || true
  fi
  local n; n="$(jq 'length' "$report" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    fail "${n} potential secret(s) — values redacted below"
    jq -r '.[] | "      \(.File):\(.StartLine)  \(.RuleID)"' "$report" 2>/dev/null | head -25
    warned "any credential that was ever committed must be treated as compromised and ROTATED"
    FINDINGS=$((FINDINGS + n)); record gitleaks fail "${n} findings"
  else
    pass "no secrets detected"; record gitleaks pass "0 findings"
  fi
}

# -------------------------------------------------------------- terraform ----
scan_terraform() {
  want terraform || return 0
  local tfdirs; tfdirs="$(terraform_dirs "$ROOT")"
  [ -n "$tfdirs" ] || { skip "no Terraform found"; return 0; }

  head2 "IaC misconfiguration — checkov"
  if have checkov; then
    local report="${OUT_DIR}/checkov.json"
    checkov -d "$ROOT" --framework terraform --output json --output-file-path "$report" \
            --quiet --compact --skip-download >/dev/null 2>&1 || true
    local f="${report}/results_json.json"; [ -r "$f" ] || f="$report"
    local n; n="$(jq '[.. | .failed_checks? // empty | length] | add // 0' "$f" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -gt 0 ]; then
      fail "${n} failed check(s)"
      jq -r '.. | .failed_checks? // empty | .[]? | "      \(.check_id) \(.file_path):\(.file_line_range[0])  \(.check_name)"' "$f" 2>/dev/null | head -20
      FINDINGS=$((FINDINGS + n)); record checkov fail "${n} findings"
    else pass "checkov clean"; record checkov pass "0 findings"; fi
  else skip "checkov not installed"; record checkov skipped ""; fi

  head2 "IaC misconfiguration — trivy config"
  if have trivy; then
    trivy config --quiet --format table --exit-code 0 "$ROOT" 2>/dev/null | sed 's/^/    /' | head -40
    record trivy-config pass "see output"
  else skip "trivy not installed"; fi

  head2 "Policy — conftest (Rego)"
  # Terraform policies only — see the note in `devbox terraform policy`.
  local pol="${DEVBOX_ROOT}/security/policy/terraform"
  [ -d "${ROOT}/security/policy/terraform" ] && pol="${ROOT}/security/policy/terraform"
  if have conftest && [ -d "$pol" ]; then
    conftest test --policy "$pol" --all-namespaces "$ROOT" 2>&1 | sed 's/^/    /' | head -30
    record conftest pass "policies evaluated"
  else skip "no Rego policies or conftest missing"; fi
}

# ------------------------------------------------------------ dependencies ---
scan_deps() {
  want deps || return 0
  head2 "Dependencies — trivy filesystem"
  if ! have trivy; then skip "trivy not installed"; return 0; fi
  local report="${OUT_DIR}/trivy-fs.json"
  trivy filesystem --quiet --scanners vuln --format json --output "$report" \
        --severity HIGH,CRITICAL "$ROOT" >/dev/null 2>&1 || true
  local n; n="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$report" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    fail "${n} HIGH/CRITICAL vulnerabilit(ies)"
    jq -r '.Results[]?.Vulnerabilities[]? | "      \(.Severity) \(.PkgName) \(.InstalledVersion) → \(.FixedVersion // "no fix") \(.VulnerabilityID)"' \
      "$report" 2>/dev/null | sort -u | head -25
    FINDINGS=$((FINDINGS + n)); record trivy-fs fail "${n} findings"
  else pass "no HIGH/CRITICAL dependency vulnerabilities"; record trivy-fs pass "0 findings"; fi
}

# --------------------------------------------------------------- code SAST ---
scan_code() {
  want code || return 0
  head2 "Static analysis — semgrep"
  if ! have semgrep; then skip "semgrep not installed"; record semgrep skipped ""; return 0; fi
  local report="${OUT_DIR}/semgrep.json"
  # `p/ci` is the curated low-false-positive ruleset. A noisy scanner is a
  # scanner people learn to ignore.
  semgrep scan --config p/ci --json --output "$report" --quiet --metrics=off "$ROOT" >/dev/null 2>&1 || true
  local n; n="$(jq '.results | length' "$report" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    fail "${n} finding(s)"
    jq -r '.results[] | "      \(.path):\(.start.line)  \(.check_id)"' "$report" 2>/dev/null | head -20
    FINDINGS=$((FINDINGS + n)); record semgrep fail "${n} findings"
  else pass "semgrep clean"; record semgrep pass "0 findings"; fi

  head2 "Shell — shellcheck"
  if have shellcheck; then
    local bad=0 f
    while IFS= read -r f; do
      shellcheck -x -S warning -f gcc "$f" 2>/dev/null | sed 's/^/      /' && continue
      bad=$((bad+1))
    done < <(find "$ROOT" -type f -name '*.sh' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
    [ "$bad" -eq 0 ] && pass "shell scripts clean" || { warned "${bad} script(s) with warnings"; }
  else skip "shellcheck not installed"; fi
}

# --------------------------------------------------------------- container ---
scan_containers() {
  want containers || return 0
  head2 "Container definitions"
  local files; files="$(find "$ROOT" -maxdepth 3 \( -name 'Containerfile*' -o -name 'Dockerfile*' \) -not -path '*/.git/*' 2>/dev/null)"
  [ -n "$files" ] || { skip "no Containerfile/Dockerfile found"; return 0; }
  if have trivy; then
    local f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      info "$(basename "$f")"
      trivy config --quiet --exit-code 0 "$f" 2>/dev/null | sed 's/^/      /' | head -20
    done <<< "$files"
    record trivy-container pass "evaluated"
  else skip "trivy not installed"; fi
}

# ----------------------------------------------------------------- actions ---
scan_actions() {
  want all || want actions || return 0
  [ -d "${ROOT}/.github/workflows" ] || return 0
  head2 "GitHub Actions"
  if have actionlint; then
    ( cd "$ROOT" && actionlint -no-color 2>&1 | sed 's/^/      /' | head -30 ) && pass "actionlint clean"
  fi
  local unpinned
  unpinned="$(grep -rhoE 'uses:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[A-Za-z0-9._/-]+' \
              "${ROOT}/.github/workflows" 2>/dev/null | grep -vE '@[0-9a-f]{40}$' | sort -u || true)"
  if [ -n "$unpinned" ]; then
    warned "actions pinned to a mutable tag rather than a commit SHA:"
    printf '%s\n' "$unpinned" | sed 's/^/      /'
    FINDINGS=$((FINDINGS + $(printf '%s\n' "$unpinned" | wc -l)))
  else pass "third-party actions pinned to commit SHAs"; fi
  # The highest-severity Actions mistake there is.
  if grep -rlE 'pull_request_target' "${ROOT}/.github/workflows" >/dev/null 2>&1; then
    warned "pull_request_target present — verify it never checks out or executes PR code"
  fi
}

# =============================================================================
main() {
  if [ "$FORMAT" = json ]; then
    # Machine-readable path: the individual tool reports are already on disk.
    for fn in scan_secrets scan_terraform scan_deps scan_code scan_containers scan_actions; do
      "$fn" >/dev/null 2>&1
    done
    printf '{"findings":%d,"reports_dir":"%s","sections":[' "$FINDINGS" "$OUT_DIR"
    local first=1 s
    for s in "${SECTIONS[@]-}"; do
      IFS='|' read -r tool status detail <<< "$s"
      [ "$first" = 1 ] || printf ','
      printf '{"tool":"%s","status":"%s","detail":"%s"}' "$tool" "$status" "$detail"
      first=0
    done
    printf ']}\n'
    return 0
  fi

  head1 "DEVBOX SECURITY SCAN"
  info "path ${ROOT}   scope ${SCOPE}"
  scan_secrets
  scan_terraform
  scan_deps
  scan_code
  scan_containers
  scan_actions

  head1 "SUMMARY"
  local s
  for s in "${SECTIONS[@]-}"; do
    IFS='|' read -r tool status detail <<< "$s"
    case "$status" in
      pass)    pass "$(printf '%-18s %s' "$tool" "$detail")" ;;
      fail)    fail "$(printf '%-18s %s' "$tool" "$detail")" ;;
      skipped) skip "$(printf '%-18s %s' "$tool" "not installed")" ;;
    esac
  done
  printf '\n  reports: %s\n' "$OUT_DIR"
  if [ "$FINDINGS" -gt 0 ]; then
    printf '  %s%d finding(s) require triage.%s Not every finding is a vulnerability —\n' "$YLW" "$FINDINGS" "$R"
    printf '  triage with: %sai review security%s\n\n' "$CYN" "$R"
  else
    printf '  %sNo findings.%s\n\n' "$GRN" "$R"
  fi
  audit_log security-scan "scope=${SCOPE} findings=${FINDINGS}"

  case "$FAIL_ON" in
    none) return 0 ;;
    *)    [ "$FINDINGS" -eq 0 ] && return 0 || return 1 ;;
  esac
}

main

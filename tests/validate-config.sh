#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Validate the DevBox configuration without building anything.
#
# Runs in CI, in pre-commit, and from `make validate`. It catches the class of
# mistake that would otherwise only surface after a 20-minute image build:
# a malformed version manifest, a policy that references a profile that does not
# exist, an MCP server enabled with no scope.
# -----------------------------------------------------------------------------
set -uo pipefail

# `list_has <needle>` — read a newline-separated list on stdin, succeed if a
# line equals <needle>. Deliberately not `grep -qx`: grep exits on first match,
# the producer takes SIGPIPE, and `pipefail` turns a present value into an
# absent one, intermittently. See bin/devbox-lib.sh for the long version.
list_has() {
  local needle="$1" line
  while IFS= read -r line; do [ "$line" = "$needle" ] && return 0; done
  return 1
}


cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1

PASS=0; FAIL=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R_=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; B=$'\033[1m'
else G=''; R_=''; Y=''; N=''; B=''; fi

ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
no()   { printf '  %s✗%s %s\n' "$R_" "$N" "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
sect() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

command -v yq >/dev/null 2>&1 || { echo "yq is required"; exit 1; }

# ---------------------------------------------------------------------------
sect "versions.yaml"
if yq -e '.' versions.yaml >/dev/null 2>&1; then ok "parses as YAML"; else no "invalid YAML"; fi

# The awk-based parser in scripts/lib/versions.sh must agree with yq. If it does
# not, the image would be built with different versions than the manifest states,
# which is the worst kind of drift because nothing reports it.
mapfile -t shell_vars < <(./scripts/lib/versions.sh 2>/dev/null | sed 's/^export //')
if [ "${#shell_vars[@]}" -gt 40 ]; then ok "shell parser emits ${#shell_vars[@]} variables"
else no "shell parser emitted only ${#shell_vars[@]} variables — expected 40+"; fi

drift=0
for sec in languages iac kubernetes security tools ai mcp; do
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    want="$(yq -r ".${sec}.${key}" versions.yaml)"
    got="$(printf '%s\n' "${shell_vars[@]}" | sed -n "s/^V_${sec}_${key}='\(.*\)'$/\1/p")"
    if [ "$want" != "$got" ]; then
      no "drift: ${sec}.${key} — yq='${want}' shell='${got}'"; drift=1
    fi
  done < <(yq -r ".${sec} // {} | keys | .[]" versions.yaml 2>/dev/null)
done
[ "$drift" = 0 ] && ok "shell parser agrees with yq on every key"

# Every exact pin should carry a Renovate annotation, or it will silently rot.
missing_renovate=0
while IFS= read -r line; do
  missing_renovate=$((missing_renovate+1))
  warn "no renovate annotation: ${line}"
done < <(awk '
  /^  # renovate:/ { ann=1; next }
  /^  [a-z_0-9]+:/ {
    val=$2; gsub(/"/,"",val)
    if (!ann && val != "latest" && val != "apt" && val !~ /^[0-9]$/ && $1 !~ /^(python|schema|base_image|base_tag|base_digest|awscli|azurecli|gcloud|github_image|terraform_image):$/)
      print $1 " " val
    ann=0; next
  }
  { ann=0 }' versions.yaml)
[ "$missing_renovate" -eq 0 ] && ok "every exact pin is Renovate-annotated" \
  || warn "${missing_renovate} pin(s) are not Renovate-managed"

# ---------------------------------------------------------------------------
sect "ai/policies/policy.yaml"
if yq -e '.' ai/policies/policy.yaml >/dev/null 2>&1; then ok "parses"; else no "invalid YAML"; fi
for k in filesystem execution secrets network limits; do
  yq -e ".${k}" ai/policies/policy.yaml >/dev/null 2>&1 && ok "section: ${k}" || no "missing section: ${k}"
done
for c in SAFE REVIEW_REQUIRED APPROVAL_REQUIRED BLOCKED; do
  n="$(yq -r ".execution.${c} | length" ai/policies/policy.yaml 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ] && ok "execution.${c}: ${n} patterns" || no "execution.${c} is empty"
done

# The specific destructive commands §18 requires MUST be BLOCKED. This test is
# the reason the policy cannot quietly regress.
sect "guardrails (§18 destructive actions)"
must_block=(
  "terraform destroy" "tofu destroy" "kubectl delete" "helm uninstall"
  "rm -rf /" "git push --force" "git reset --hard"
  "aws s3 delete-object" "az group delete" "gcloud compute instances delete"
)
for cmd in "${must_block[@]}"; do
  matched=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$cmd" in $pat) matched="$pat"; break ;; esac
  done < <(yq -r '.execution.BLOCKED[]' ai/policies/policy.yaml 2>/dev/null)
  [ -n "$matched" ] && ok "BLOCKED: ${cmd}  (matches '${matched}')" \
                    || no "NOT BLOCKED: ${cmd}"
done

# `terraform apply` must not be SAFE. It may be APPROVAL_REQUIRED.
apply_class=""
for class in BLOCKED APPROVAL_REQUIRED REVIEW_REQUIRED SAFE; do
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    # shellcheck disable=SC2194  # the literal is the subject under test
    case "terraform apply" in $pat) apply_class="$class"; break 2 ;; esac
  done < <(yq -r ".execution.${class}[]" ai/policies/policy.yaml 2>/dev/null)
done
case "$apply_class" in
  APPROVAL_REQUIRED|BLOCKED) ok "terraform apply is ${apply_class}" ;;
  *) no "terraform apply is '${apply_class:-unclassified}' — must be APPROVAL_REQUIRED or stricter" ;;
esac

# ---------------------------------------------------------------------------
sect "ai/models"
for f in models.yaml profiles.yaml routing.yaml router.yaml; do
  yq -e '.' "ai/models/${f}" >/dev/null 2>&1 && ok "${f} parses" || no "${f} invalid"
done

# Every profile must name a provider that exists.
while IFS= read -r prof; do
  [ -n "$prof" ] || continue
  prov="$(yq -r ".profiles.${prof}.provider" ai/models/profiles.yaml)"
  if yq -e ".providers.${prov}" ai/models/models.yaml >/dev/null 2>&1; then
    ok "profile ${prof} → provider ${prov}"
  else
    no "profile ${prof} references unknown provider '${prov}'"
  fi
  # And an MCP trust profile that exists.
  mprof="$(yq -r ".profiles.${prof}.mcp_profile" ai/models/profiles.yaml)"
  yq -e ".profiles.${mprof}" mcp/profiles.yaml >/dev/null 2>&1 \
    || no "profile ${prof} references unknown MCP trust profile '${mprof}'"
done < <(yq -r '.profiles | keys | .[]' ai/models/profiles.yaml 2>/dev/null)

# The default profile must exist.
defp="$(yq -r '.default' ai/models/profiles.yaml)"
yq -e ".profiles.${defp}" ai/models/profiles.yaml >/dev/null 2>&1 \
  && ok "default profile '${defp}' exists" || no "default profile '${defp}' does not exist"

# Every workflow must respect the policy step limit and end at a human.
maxsteps="$(yq -r '.limits.max_workflow_steps' ai/policies/policy.yaml)"
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  n="$(yq -r ".workflows.${wf}.steps | length" ai/models/routing.yaml)"
  last="$(yq -r ".workflows.${wf}.steps[-1].kind" ai/models/routing.yaml)"
  if [ "$n" -gt "$maxsteps" ]; then no "workflow ${wf} has ${n} steps, limit is ${maxsteps}"
  elif [ "$last" != "human" ]; then no "workflow ${wf} does not end at a human step"
  else ok "workflow ${wf}: ${n} steps, ends at human"; fi
done < <(yq -r '.workflows | keys | .[]' ai/models/routing.yaml 2>/dev/null)

# ---------------------------------------------------------------------------
sect "mcp"
for f in servers.yaml policies.yaml profiles.yaml; do
  yq -e '.' "mcp/${f}" >/dev/null 2>&1 && ok "${f} parses" || no "${f} invalid"
done

[ "$(yq -r '.default' mcp/profiles.yaml)" = "READ_ONLY" ] \
  && ok "default MCP trust profile is READ_ONLY" \
  || no "default MCP trust profile must be READ_ONLY (§16)"

# No restricted-trust server may be enabled by default in the committed registry.
while IFS= read -r s; do
  [ -n "$s" ] || continue
  no "restricted-trust server '${s}' is enabled in the committed registry"
done < <(yq -r '.servers | to_entries[] | select(.value.enabled == true and .value.trust == "restricted") | .key' mcp/servers.yaml 2>/dev/null)
ok "no restricted-trust server enabled by default"

# Every read-write server must declare a scope.
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if yq -e ".servers.${s}.scope" mcp/servers.yaml >/dev/null 2>&1; then
    ok "read-write server '${s}' declares a scope"
  else
    no "read-write server '${s}' has NO scope"
  fi
done < <(yq -r '.servers | to_entries[] | select(.value.access == "read-write") | .key' mcp/servers.yaml 2>/dev/null)

# Container-transport servers must declare the hardening flags.
while IFS= read -r s; do
  [ -n "$s" ] || continue
  miss=""
  args="$(yq -r ".servers.${s}.container_args[]?" mcp/servers.yaml)"
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    # NOT `yq ... | grep -qxF`: grep exits on the first match, yq takes
    # SIGPIPE, and under `pipefail` the pipeline reports 141 — so a required
    # arg that IS present reads as missing. Intermittent (~2.5% per lookup),
    # which is exactly how it passed locally and failed in CI.
    printf '%s\n' "$args" | list_has "$req" || miss="${miss} ${req}"
  done < <(yq -r '.requirements.container_hardening.required_args[]' mcp/policies.yaml)
  [ -z "$miss" ] && ok "container server '${s}' is hardened" || no "container server '${s}' missing:${miss}"
done < <(yq -r '.servers | to_entries[] | select(.value.transport == "container") | .key' mcp/servers.yaml 2>/dev/null)

# No server may request a globally denied environment variable.
leak=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    while IFS= read -r denied; do
      [ -n "$denied" ] || continue
      # shellcheck disable=SC2254
      case "$ev" in $denied) no "server '${s}' requests denied env var ${ev}"; leak=1 ;; esac
    done < <(yq -r '.global_deny.environment_variables[]' mcp/policies.yaml)
  done < <(yq -r ".servers.${s}.env_passthrough[]?" mcp/servers.yaml)
done < <(yq -r '.servers | keys | .[]' mcp/servers.yaml 2>/dev/null)
[ "$leak" = 0 ] && ok "no MCP server requests a denied credential"

# ---------------------------------------------------------------------------
sect "agents and prompts"
for f in ai/agents/*.md; do
  b="$(basename "$f" .md)"; [ "$b" = README ] && continue
  prof="$(awk -F': *' '/^profile:/{print $2; exit}' "$f")"
  if [ -z "$prof" ]; then no "agent ${b}: no profile in front matter"
  elif yq -e ".profiles.${prof}" ai/models/profiles.yaml >/dev/null 2>&1; then ok "agent ${b} → ${prof}"
  else no "agent ${b} references unknown profile '${prof}'"; fi
done
for f in ai/prompts/*.md; do
  b="$(basename "$f" .md)"; [ "$b" = README ] && continue
  ag="$(awk -F': *' '/^agent:/{print $2; exit}' "$f")"
  if [ -n "$ag" ] && [ ! -r "ai/agents/${ag}.md" ]; then
    no "prompt ${b} references unknown agent '${ag}'"
  else ok "prompt ${b}"; fi
done

# Every agent role referenced by a workflow must exist.
while IFS= read -r role; do
  [ -n "$role" ] || continue
  [ -r "ai/agents/${role}.md" ] && ok "workflow role ${role} exists" \
    || no "workflow references unknown agent role '${role}'"
done < <(yq -r '.workflows[].steps[] | select(.kind == "agent") | .role' ai/models/routing.yaml 2>/dev/null | sort -u)

# ---------------------------------------------------------------------------
sect "release model"
# Two independent version streams, and the DevBox consumes a PUBLISHED base
# rather than rebuilding one. These checks exist because every one of them is a
# way the model can silently degrade back into "rebuild everything each time".
for k in base devbox; do
  v="$(yq -r ".release.${k} // \"\"" versions.yaml)"
  if printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "release.${k} is a semver (${v})"
  else
    no "release.${k} must be MAJOR.MINOR.PATCH, got '${v}'"
  fi
done

pinned_base="$(yq -r '.release.base' versions.yaml)"

# The Containerfile's default base ref must name the pinned version. If it
# drifts, a local `podman build` silently produces a DevBox on a different
# foundation than CI built, and the two are indistinguishable afterwards.
cf_base="$(awk -F= '/^ARG BASE_IMAGE_REF=/{print $2; exit}' Containerfile)"
case "$cf_base" in
  *":${pinned_base}") ok "Containerfile default base matches release.base (${pinned_base})" ;;
  *:latest | *:edge) no "Containerfile default base is a floating tag (${cf_base}) — pin it to release.base" ;;
  *) no "Containerfile default base '${cf_base}' does not match release.base '${pinned_base}'" ;;
esac

# Same for compose, which is what `docker compose up` and the devcontainer use.
compose_base="$(awk -F'-' '/BASE_IMAGE_REF: \$\{DEVBOX_BASE_IMAGE:/{sub(/\}.*/,"",$NF); print $NF; exit}' compose.yaml)"
case "$compose_base" in
  *":${pinned_base}") ok "compose default base matches release.base (${pinned_base})" ;;
  "") no "compose.yaml has no BASE_IMAGE_REF default" ;;
  *) no "compose default base '${compose_base}' does not match release.base '${pinned_base}'" ;;
esac

# The registry is the source of base images. A local-only default would work on
# the machine that built it and nowhere else.
case "$cf_base" in
  ghcr.io/*) ok "Containerfile pulls its base from a registry" ;;
  *) no "Containerfile base '${cf_base}' is not a registry reference" ;;
esac

# Helper scripts the workflows depend on must exist and be executable, or the
# failure surfaces as an inscrutable 'Permission denied' halfway through CI.
for h in image-ref.sh podman-build.sh publish-image.sh; do
  if [ -x ".github/scripts/${h}" ]; then ok "${h} is executable"
  else no ".github/scripts/${h} missing or not executable"; fi
done

sect "container definitions"
for cf in Containerfile Containerfile.base; do
  grep -qE '^USER +\$\{?DEV_USER' "$cf" && ok "${cf}: ends as non-root" || no "${cf}: no non-root USER"
  grep -q 'HEALTHCHECK' "$cf" && ok "${cf}: has a HEALTHCHECK" || warn "${cf}: no HEALTHCHECK"
  # BuildKit-only syntax must not creep in — podman/buildah must build this.
  grep -qE '^RUN --mount' "$cf" && no "${cf}: uses BuildKit-only RUN --mount" || ok "${cf}: BuildKit-independent"
  grep -qE '<<[A-Z]' "$cf" && no "${cf}: uses BuildKit-only heredoc" || ok "${cf}: no heredocs"
done

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '  %s%d checks passed%s\n\n' "$G" "$PASS" "$N"; exit 0
else
  printf '  %s%d passed, %d FAILED%s\n\n' "$R_" "$PASS" "$FAIL" "$N"; exit 1
fi

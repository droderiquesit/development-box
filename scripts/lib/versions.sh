#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Render versions.yaml into shell variables.
#
# We deliberately do NOT use yq here: this file is sourced during the very first
# layers of the base image build, long before any tool is installed. A ~20 line
# awk parser over a deliberately simple two-level YAML subset removes the
# chicken-and-egg problem and keeps versions.yaml the only place a version lives.
#
# Usage:
#   source scripts/lib/versions.sh [path/to/versions.yaml]
#   echo "$V_iac_terraform"
#
# Emitted variable names are  V_<section>_<key>  with dots/dashes normalised.
# -----------------------------------------------------------------------------
set -euo pipefail

devbox_versions_file() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return; fi
  for candidate in \
    "${DEVBOX_VERSIONS_FILE:-}" \
    "./versions.yaml" \
    "/opt/devbox/versions.yaml" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/versions.yaml"
  do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return; }
  done
  echo "versions.sh: cannot locate versions.yaml" >&2
  return 1
}

# Print `export V_section_key='value'` lines for the whole manifest.
devbox_versions_export_lines() {
  local file
  file="$(devbox_versions_file "${1:-}")"
  awk '
    # Strip trailing comments that are preceded by whitespace, then trailing ws.
    { line = $0
      sub(/[ \t]+#.*$/, "", line)
      sub(/[ \t]+$/, "", line)
    }
    line ~ /^[ \t]*$/          { next }
    line ~ /^#/                { next }
    # Top level section:  "iac:"
    line ~ /^[A-Za-z_][A-Za-z0-9_]*:[ \t]*$/ {
      section = line; sub(/:[ \t]*$/, "", section); next
    }
    # Nested scalar:  "  terraform: 1.15.8"
    line ~ /^[ \t]+[A-Za-z_][A-Za-z0-9_]*:[ \t]*.+$/ {
      if (section == "") next
      key = line
      sub(/^[ \t]+/, "", key)
      idx = index(key, ":")
      val = substr(key, idx + 1)
      key = substr(key, 1, idx - 1)
      sub(/^[ \t]+/, "", val)
      # Unquote
      if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
      else if (val ~ /^'"'"'.*'"'"'$/) { val = substr(val, 2, length(val) - 2) }
      gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", val)
      printf "export V_%s_%s='"'"'%s'"'"'\n", section, key, val
    }
  ' "$file"
}

# Load the manifest into the current shell.
devbox_load_versions() {
  local lines
  lines="$(devbox_versions_export_lines "${1:-}")"
  eval "$lines"
}

# When executed (not sourced) print the export lines — handy for Containerfiles,
# Makefiles and CI:  eval "$(scripts/lib/versions.sh)"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  devbox_versions_export_lines "${1:-}"
else
  devbox_load_versions "${1:-}" || true
fi

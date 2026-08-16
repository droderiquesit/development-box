# =============================================================================
# Container image policy (§31)
# =============================================================================
# Evaluated by conftest against the Containerfile in CI (the base image's
# Containerfile lives in — and is policy-checked by — the Base Image Factory).
# These are the image requirements this repository commits to, expressed as code
# rather than as a paragraph in a README that nobody re-reads.
package main

import rego.v1

# --- non-root ---------------------------------------------------------------
# The final USER instruction must not be root. A dev container that runs as root
# hands every AI tool and every MCP server uid 0 inside the namespace.
deny contains msg if {
	some i
	input[i].Cmd == "user"
	last_user := last_user_value
	last_user in {"root", "0"}
	msg := sprintf("image must not run as root (final USER is %q)", [last_user])
}

last_user_value := u if {
	users := [v |
		some i
		input[i].Cmd == "user"
		v := input[i].Value[0]
	]
	count(users) > 0
	u := users[count(users) - 1]
}

deny contains msg if {
	not last_user_value
	msg := "image declares no USER instruction — it would run as root"
}

# --- base image pinning ------------------------------------------------------
warn contains msg if {
	some i
	input[i].Cmd == "from"
	val := input[i].Value[0]
	not contains(val, "@sha256:")
	not contains(val, "$")
	not contains(val, " AS ")
	msg := sprintf("base image %q is not pinned by digest — reproducibility depends on a mutable tag", [val])
}

# --- no embedded secrets -----------------------------------------------------
secret_pattern := `(?i)(api[_-]?key|secret|password|passwd|token|private[_-]?key)\s*[:=]\s*\S{8,}`

deny contains msg if {
	some i
	input[i].Cmd in {"env", "arg"}
	val := concat(" ", input[i].Value)
	regex.match(secret_pattern, val)
	msg := sprintf("possible embedded credential in %s: %s", [input[i].Cmd, val])
}

deny contains msg if {
	some i
	input[i].Cmd == "run"
	val := concat(" ", input[i].Value)
	regex.match(`(gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})`, val)
	msg := "credential-shaped literal found in a RUN instruction"
}

# --- no curl | bash ----------------------------------------------------------
# §31: prefer verified package/binary installation over unverified pipe-to-shell.
deny contains msg if {
	some i
	input[i].Cmd == "run"
	val := concat(" ", input[i].Value)
	regex.match(`(curl|wget)[^|]*\|\s*(sudo\s+)?(ba)?sh`, val)
	msg := "curl-pipe-shell installation is not permitted — use a signed repo or a checksum-verified download"
}

# --- healthcheck -------------------------------------------------------------
warn contains msg if {
	not has_healthcheck
	msg := "image declares no HEALTHCHECK — `devbox doctor` cannot report container state to the runtime"
}

has_healthcheck if {
	some i
	input[i].Cmd == "healthcheck"
}

# --- BuildKit independence ---------------------------------------------------
# §2: the build must work under podman/buildah without BuildKit.
deny contains msg if {
	some i
	input[i].Cmd == "run"
	val := concat(" ", input[i].Value)
	startswith(val, "--mount")
	msg := "RUN --mount is BuildKit-only; this image must build with podman/buildah"
}

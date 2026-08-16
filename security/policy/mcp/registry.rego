# =============================================================================
# MCP registry policy (§15, §16)
# =============================================================================
# Evaluated by conftest against mcp/servers.yaml. Enforces the invariants that
# make the registry an allowlist rather than a wish list.
package main

import rego.v1

servers := object.get(input, "servers", {})

# --- default posture ---------------------------------------------------------
deny contains msg if {
	object.get(input, ["metadata", "default_trust_profile"], "") != "READ_ONLY"
	msg := "default_trust_profile must be READ_ONLY (§16)"
}

# --- restricted servers are never on by default ------------------------------
deny contains msg if {
	some name, s in servers
	s.trust == "restricted"
	s.enabled == true
	msg := sprintf("server %q has trust=restricted and must not be enabled in the committed registry", [name])
}

# --- read-write requires a declared scope ------------------------------------
deny contains msg if {
	some name, s in servers
	s.access == "read-write"
	not s.scope
	msg := sprintf("server %q is read-write but declares no scope — an unscoped read-write server is exactly the risk this layer exists to prevent", [name])
}

# --- container servers must be hardened --------------------------------------
required_container_args := {
	"--security-opt=no-new-privileges",
	"--cap-drop=ALL",
	"--read-only",
	"--rm",
}

deny contains msg if {
	some name, s in servers
	s.transport == "container"
	some required in required_container_args
	not required in object.get(s, "container_args", [])
	msg := sprintf("container server %q is missing hardening flag %q", [name, required])
}

# --- every server states why it exists ---------------------------------------
warn contains msg if {
	some name, s in servers
	not s.rationale
	msg := sprintf("server %q has no rationale — every entry must justify its existence (§44)", [name])
}

# --- filesystem scoping ------------------------------------------------------
deny contains msg if {
	fs := object.get(servers, "filesystem", {})
	fs.enabled == true
	paths := object.get(fs, ["scope", "allowed_paths"], [])
	count(paths) == 0
	msg := "the filesystem server is enabled with no allowed_paths — it would see the entire filesystem"
}

credential_paths := {"~/.ssh", "~/.aws", "~/.azure", "~/.config/gcloud", "~/.kube", "/run/secrets"}

deny contains msg if {
	some name, s in servers
	some p in object.get(s, ["scope", "allowed_paths"], [])
	some cred in credential_paths
	startswith(p, cred)
	msg := sprintf("server %q allows a credential path %q", [name, p])
}

# --- fetch must be allowlisted -----------------------------------------------
deny contains msg if {
	f := object.get(servers, "fetch", {})
	f.enabled == true
	count(object.get(f, ["scope", "allowed_domains"], [])) == 0
	msg := "the fetch server is enabled with no domain allowlist — that is an exfiltration primitive"
}

# =============================================================================
# Terraform baseline policy
# =============================================================================
# A deliberately small starter set evaluated by `devbox terraform policy`. It is
# intentionally NOT a rewrite of Checkov: these are the repository conventions
# that a generic scanner cannot know about. Extend it per project.
package main

import rego.v1

# --- version constraints -----------------------------------------------------
warn contains msg if {
	some path, blocks in input
	endswith(path, ".tf")
	tf := object.get(blocks, "terraform", [])
	count(tf) > 0
	not has_required_version(tf)
	msg := sprintf("%s: terraform block has no required_version constraint", [path])
}

has_required_version(blocks) if {
	some b in blocks
	b.required_version
}

# --- no hardcoded credentials in variable defaults ---------------------------
deny contains msg if {
	some path, blocks in input
	some name, v in object.get(blocks, "variable", {})
	d := object.get(v, "default", "")
	is_string(d)
	regex.match(`^(AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{16,})$`, d)
	msg := sprintf("%s: variable %q has a credential-shaped default value", [path, name])
}

# --- sensitive variables must be marked --------------------------------------
warn contains msg if {
	some path, blocks in input
	some name, v in object.get(blocks, "variable", {})
	regex.match(`(?i)(password|secret|token|key|credential)`, name)
	not object.get(v, "sensitive", false)
	msg := sprintf("%s: variable %q looks sensitive but is not marked `sensitive = true`", [path, name])
}

# --- variables need types and descriptions -----------------------------------
warn contains msg if {
	some path, blocks in input
	some name, v in object.get(blocks, "variable", {})
	not v.description
	msg := sprintf("%s: variable %q has no description", [path, name])
}

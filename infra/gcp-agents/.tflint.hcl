# Repository-local tflint configuration for infra/gcp-agents.
# Mirrors config/terraform/.tflint.hcl and adds the Google ruleset, which
# catches invalid machine types, disk types and similar typos at lint time.

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "google" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs" { enabled = true }
rule "terraform_typed_variables" { enabled = true }
rule "terraform_naming_convention" { enabled = true }
rule "terraform_required_version" { enabled = true }
rule "terraform_required_providers" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_comment_syntax" { enabled = true }

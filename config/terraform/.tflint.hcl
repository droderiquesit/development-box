# Default tflint configuration shipped with the DevBox.
# A repository-local .tflint.hcl always takes precedence.

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Cloud provider rulesets are commented out rather than enabled: each one is a
# separate plugin download at `tflint --init` time, and enabling all three by
# default would make the first lint of any repository slow and noisy. Uncomment
# the one you actually use, or put it in your repo-local config.
#
# plugin "aws" {
#   enabled = true
#   version = "0.44.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-aws"
# }
# plugin "azurerm" {
#   enabled = true
#   version = "0.30.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
# }
# plugin "google" {
#   enabled = true
#   version = "0.35.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-google"
# }

rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_documented_variables"     { enabled = true }
rule "terraform_documented_outputs"       { enabled = true }
rule "terraform_typed_variables"          { enabled = true }
rule "terraform_naming_convention"        { enabled = true }
rule "terraform_required_version"         { enabled = true }
rule "terraform_required_providers"       { enabled = true }
rule "terraform_unused_declarations"      { enabled = true }
rule "terraform_comment_syntax"           { enabled = true }

output "generated_files" {
  description = "Paths of the generated environment files, keyed by environment."
  value       = { for k, f in local_file.environment : k => f.filename }
}

output "network_ids" {
  description = "Network identifiers produced by the example-network module."
  value       = { for k, m in module.network : k => m.network_id }
}

output "subnet_cidrs" {
  description = "Subnet CIDR blocks per environment."
  value       = { for k, m in module.network : k => m.subnet_cidrs }
}

# `sensitive = true` keeps a value out of plan output, state diffs and CI logs.
# Any output that carries a credential, connection string or key must be marked
# this way — the DevBox Rego policy warns when a credential-shaped name is not.
output "instance_suffixes" {
  description = "Per-environment random suffixes. Marked sensitive to demonstrate the practice."
  value       = { for k, r in random_id.suffix : k => r.hex }
  sensitive   = true
}

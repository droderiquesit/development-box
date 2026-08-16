output "network_id" {
  description = "Stable identifier for the generated network."
  value       = var.name
}

output "subnet_cidrs" {
  description = "The computed subnet CIDR blocks."
  value       = local.subnet_cidrs
}

output "cidr_block" {
  description = "The network CIDR block, echoed for composition."
  value       = var.cidr_block
}

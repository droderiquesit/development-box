# A module with one job and a clean interface. It computes subnet CIDRs and
# records the result; there is no cloud provider involved, so it runs anywhere.

terraform {
  required_version = ">= 1.5"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

locals {
  # cidrsubnet is deterministic, so the plan is stable across runs.
  subnet_cidrs = [
    for i in range(var.subnet_count) : cidrsubnet(var.cidr_block, 8, i)
  ]
  label_lines = join("\n", [for k, v in var.common_labels : "  ${k} = ${v}"])
}

resource "local_file" "network" {
  filename        = "${path.module}/../../generated/network-${var.name}.txt"
  file_permission = "0644"
  content         = <<-EOT
    network = ${var.name}
    cidr    = ${var.cidr_block}
    subnets =
    ${join("\n", [for c in local.subnet_cidrs : "  ${c}"])}
    labels =
    ${local.label_lines}
  EOT
}

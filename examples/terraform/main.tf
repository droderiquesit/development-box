# =============================================================================
# DevBox Terraform example
# =============================================================================
# Uses only the local and random providers: no credentials, no cost, runs
# anywhere. Its purpose is to exercise the whole validation chain.

terraform {
  required_version = ">= 1.5"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# `for_each` rather than `count`: removing an element from the middle of a
# count-indexed list reindexes everything after it, which destroys and recreates
# resources that should not have been touched.
resource "local_file" "environment" {
  for_each = var.environments

  filename        = "${path.module}/generated/${each.key}.txt"
  content         = <<-EOT
    environment = ${each.key}
    region      = ${each.value.region}
    replicas    = ${each.value.replicas}
    suffix      = ${random_id.suffix[each.key].hex}
  EOT
  file_permission = "0644"
}

resource "random_id" "suffix" {
  for_each    = var.environments
  byte_length = 4
}

module "network" {
  source = "./modules/example-network"

  for_each = var.environments

  name          = "${var.project_name}-${each.key}"
  cidr_block    = each.value.cidr_block
  subnet_count  = each.value.replicas
  common_labels = merge(var.common_labels, { environment = each.key })
}

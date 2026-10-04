# =============================================================================
# Hermes agents on Cloud Run — provider and backend pins (match infra/gcp-models)
# =============================================================================
# Write-only secret data (the dashboard session secret never enters state or a
# saved plan) needs Terraform >= 1.11.

terraform {
  required_version = "~> 1.15"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Partial configuration, like infra/gcp-models:
  #   terraform init -backend-config="bucket=<state bucket>" -backend-config="prefix=gcp-agents"
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(var.labels, {
    app        = "devbox-agents"
    managed-by = "terraform"
  })
}

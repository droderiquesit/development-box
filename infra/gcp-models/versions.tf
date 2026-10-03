# =============================================================================
# Self-hosted open-weight models on Compute Engine — provider and backend pins
# =============================================================================
# Write-only arguments and ephemeral resources (used for the API key, so it is
# never stored in state or in a saved plan) need Terraform >= 1.11; the pin
# tracks versions.yaml `iac.terraform` (1.15.x).

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

  # Partial configuration: bucket and prefix are supplied at init time, e.g.
  #   terraform init -backend-config="bucket=<state bucket>" \
  #                  -backend-config="prefix=gcp-models"
  # The bucket is created by bootstrap.sh (versioned, uniform access, public
  # access prevention enforced).
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # The Billing Budgets API refuses service-account callers unless a quota
  # project is named. This makes every API call bill quota to var.project_id,
  # which is why the CI identities hold roles/serviceusage.serviceUsageConsumer.
  user_project_override = true
  billing_project       = var.project_id

  default_labels = merge(var.labels, {
    app        = "devbox-models"
    managed-by = "terraform"
  })
}

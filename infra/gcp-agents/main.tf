# =============================================================================
# Hermes agents on Cloud Run — one service per agent, behind IAP.
# =============================================================================
# Each agent: its own https://…run.app URL, Google sign-in (IAP) for
# var.users only, then the Hermes dashboard's own password. Scales to zero when
# idle (state is snapshotted to the bucket by the container), never more than
# one instance (Hermes state is single-writer). Models: Vertex AI managed open
# models, called with the agent's service account — no keys.

data "google_project" "this" {}

locals {
  name          = "devbox-agents"
  registry      = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.agents.repository_id}"
  image         = "${local.registry}/hermes-agent@${var.image_digest}"
  deploy_agents = var.image_digest == "" ? {} : var.agents
  iap_agent     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-iap.iam.gserviceaccount.com"
}

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iap.googleapis.com",
    "aiplatform.googleapis.com",
    "secretmanager.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# --- image registry -----------------------------------------------------------

resource "google_artifact_registry_repository" "agents" {
  #checkov:skip=CKV_GCP_84:Agent images hold no secrets; Google-managed encryption, no KMS key to run.
  repository_id = local.name
  location      = var.region
  format        = "DOCKER"
  description   = "DevBox Hermes agent images (deployed by digest)."

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days, outside the 10 most recent
    }
  }

  depends_on = [google_project_service.apis]
}

# --- agent state (Hermes snapshots + workspace tarballs) ----------------------

resource "google_storage_bucket" "state" {
  #checkov:skip=CKV_GCP_62:Access logging to another bucket adds cost without value for a single-user state bucket; Cloud Audit Logs cover access.
  name                        = "${var.project_id}-devbox-agent-state"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

# --- identity -----------------------------------------------------------------

resource "google_service_account" "agent" {
  account_id   = "devbox-agent"
  display_name = "DevBox Hermes agents (Cloud Run)"
}

# aiplatform.user: call Vertex AI MaaS models. Writers for logs and metrics.
resource "google_project_iam_member" "agent" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.agent.member
}

resource "google_storage_bucket_iam_member" "agent_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = google_service_account.agent.member
}

# --- secrets --------------------------------------------------------------------
# Session-signing secret: generated, write-only (never in state). The password
# hash and GitHub token are added by YOU (set-dashboard-password.sh, gcloud).

ephemeral "random_password" "session" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "this" {
  for_each  = toset(["hermes-dashboard-secret", "hermes-dashboard-password-hash", "hermes-agents-github-token"])
  secret_id = each.value

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "session" {
  secret                 = google_secret_manager_secret.this["hermes-dashboard-secret"].id
  secret_data_wo         = ephemeral.random_password.session.result
  secret_data_wo_version = 1
}

resource "google_secret_manager_secret_iam_member" "agent" {
  for_each  = google_secret_manager_secret.this
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.agent.member
}

# --- one Cloud Run service per agent ----------------------------------------

resource "google_cloud_run_v2_service" "agent" {
  for_each = local.deploy_agents

  name                = "hermes-${each.key}"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  iap_enabled         = true
  launch_stage        = "BETA" # Cloud Run's native IAP integration
  deletion_protection = false

  template {
    service_account                  = google_service_account.agent.email
    timeout                          = "3600s"
    session_affinity                 = true
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0
      max_instance_count = 1 # Hermes state is single-writer
    }

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = each.value.cpu
          memory = each.value.memory
        }
        cpu_idle          = false # agents work between requests
        startup_cpu_boost = true
      }

      startup_probe {
        tcp_socket {
          port = 8080
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 48 # restore + dashboard start, up to ~4 min
      }

      env {
        name  = "AGENT_NAME"
        value = each.key
      }
      env {
        name  = "AGENT_STATE_BUCKET"
        value = google_storage_bucket.state.name
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "VERTEX_REGION"
        value = "global"
      }
      env {
        name  = "HERMES_MODEL"
        value = each.value.model
      }
      env {
        name  = "HERMES_DASHBOARD_BASIC_AUTH_USERNAME"
        value = var.dashboard_username
      }
      env {
        name = "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.this["hermes-dashboard-password-hash"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "HERMES_DASHBOARD_BASIC_AUTH_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.this["hermes-dashboard-secret"].secret_id
            version = "latest"
          }
        }
      }
      dynamic "env" {
        for_each = var.github_token_secret_enabled ? [1] : []
        content {
          name = "GH_TOKEN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this["hermes-agents-github-token"].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.agent,
    google_storage_bucket_iam_member.agent_state,
    google_secret_manager_secret_iam_member.agent,
    google_secret_manager_secret_version.session,
  ]
}

# IAP calls the service as its service agent; only IAP may invoke it.
resource "google_cloud_run_v2_service_iam_member" "iap_invoker" {
  for_each = google_cloud_run_v2_service.agent
  name     = each.value.name
  location = var.region
  role     = "roles/run.invoker"
  member   = local.iap_agent
}

# Who may sign in through IAP.
resource "google_iap_web_cloud_run_service_iam_member" "users" {
  for_each = {
    for pair in setproduct(keys(google_cloud_run_v2_service.agent), var.users) :
    "${pair[0]}|${pair[1]}" => { agent = pair[0], member = pair[1] }
  }
  project                = var.project_id
  location               = var.region
  cloud_run_service_name = google_cloud_run_v2_service.agent[each.value.agent].name
  role                   = "roles/iap.httpsResourceAccessor"
  member                 = each.value.member
}

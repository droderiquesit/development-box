variable "project_id" {
  description = "GCP project to deploy the agents into."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Artifact Registry, the state bucket and secrets."
  type        = string
  default     = "us-central1"
}

variable "image_digest" {
  description = "Digest (sha256:…) of the hermes-agent image in this root's Artifact Registry repo. Empty = create the registry, bucket, secrets and identities only (first apply, before an image exists)."
  type        = string
  default     = ""

  validation {
    condition     = var.image_digest == "" || can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be empty or sha256:<64 hex>."
  }
}

variable "agents" {
  description = "One Cloud Run service per agent. Add a key to spin up another agent; remove it to delete that agent (its saved state stays in the bucket)."
  type = map(object({
    model  = optional(string, "zai-org/glm-5.2-maas")
    cpu    = optional(string, "2")
    memory = optional(string, "4Gi")
  }))
  default = {
    main = {}
  }

  validation {
    condition     = alltrue([for k in keys(var.agents) : can(regex("^[a-z][a-z0-9-]{0,30}$", k))])
    error_message = "Agent names must be lowercase letters, digits and dashes (they become service names)."
  }
}

variable "users" {
  description = "Google principals allowed through IAP to the agents, e.g. user:me@example.com."
  type        = list(string)
}

variable "dashboard_username" {
  description = "Username for the Hermes dashboard's own login (second factor behind IAP)."
  type        = string
  default     = "admin"
}

variable "github_token_secret_enabled" {
  description = "Mount the `hermes-agents-github-token` secret as GH_TOKEN so agents can push branches and open PRs. Add a secret version before enabling."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Extra labels applied to every resource."
  type        = map(string)
  default     = {}
}

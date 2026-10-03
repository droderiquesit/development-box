# =============================================================================
# Inputs
# =============================================================================

variable "project_id" {
  description = "GCP project that hosts the models. Supplied by CI from the GCP_PROJECT_ID repository variable."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  description = "Region for the VPC, Cloud NAT, the API-key secret replica and (by convention) the weights bucket."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = <<-EOT
    Zone for every model VM. us-central1-b is the only us-central1 zone that
    lists A3 Ultra (H200) in the GPU regions/zones table (checked 2026-10-02).
    Spot capacity for a3-ultragpu-8g is scarce; us-east4-b, us-south1-b and
    us-west1-c also list A3 Ultra.
  EOT
  type        = string
  default     = "us-central1-b"
}

# -----------------------------------------------------------------------------
# Model catalogue
# -----------------------------------------------------------------------------
# Keys are the DevBox contract: instance `devbox-model-<key>`, served model
# name `<key>`, IAP tunnel to localhost:18001 (architect) / 18002 (coder) /
# 18003 (fast). Change the model behind a key here; never rename the key.
#
# hf_revision pins the exact Hugging Face commit. stage-weights.sh copies that
# commit to gs://<weights bucket>/<hf_repo>/<hf_revision>/ once; the VM copies
# from there on every boot. The VM never talks to Hugging Face.
variable "models" {
  description = "Models to serve, keyed by the DevBox model key (architect, coder, fast)."
  type = map(object({
    hf_repo        = string
    hf_revision    = string
    license        = string
    weights_gb     = number
    machine_type   = string
    max_model_len  = number
    vllm_args      = list(string)
    env            = optional(map(string), {})
    boot_disk_gb   = optional(number, 150)
    boot_disk_type = optional(string, "hyperdisk-balanced")
  }))

  default = {
    # Kimi K2.6 — 1.03T total / 32B active MoE, native INT4 (~595 GB).
    # Flags: vllm-project/recipes models/moonshotai/Kimi-K2.6.yaml (H200 verified).
    architect = {
      hf_repo       = "moonshotai/Kimi-K2.6"
      hf_revision   = "7eb5002f6aadc958aed6a9177b7ed26bb94011bb"
      license       = "modified-mit"
      weights_gb    = 596
      machine_type  = "a3-ultragpu-8g"
      max_model_len = 262144
      vllm_args = [
        "--trust-remote-code",
        "--tensor-parallel-size", "8",
        "--mm-encoder-tp-mode", "data",
        "--tool-call-parser", "kimi_k2",
        "--enable-auto-tool-choice",
        "--reasoning-parser", "kimi_k2",
      ]
    }

    # DeepSeek V4 Pro (official 2026-08-13 release) — 1.6T total / 49B active,
    # FP4+FP8 mixed (~893 GB). Flags: recipes models/deepseek-ai/DeepSeek-V4-Pro.yaml,
    # H200 hardware override + single-node TP8/EP strategy.
    coder = {
      hf_repo       = "deepseek-ai/DeepSeek-V4-Pro-0813"
      hf_revision   = "72e1d3230f6c080a530b0a1d46f8eb4602340597"
      license       = "mit"
      weights_gb    = 893
      machine_type  = "a3-ultragpu-8g"
      max_model_len = 200000
      vllm_args = [
        "--trust-remote-code",
        "--tensor-parallel-size", "8",
        "--enable-expert-parallel",
        "--kv-cache-dtype", "fp8",
        "--block-size", "256",
        "--gpu-memory-utilization", "0.95",
        "--max-num-seqs", "16",
        "--no-enable-flashinfer-autotune",
        "--compilation-config", "{\"mode\": 0, \"cudagraph_mode\": \"FULL_DECODE_ONLY\"}",
        "--tokenizer-mode", "deepseek_v4",
        "--tool-call-parser", "deepseek_v4",
        "--enable-auto-tool-choice",
        "--reasoning-parser", "deepseek_v4",
      ]
    }

    # GLM-5.3 — 743B total / 39B active, native FP8 (~756 GB).
    # Flags: recipes models/zai-org/GLM-5.3.yaml, "FP8 on 8xH200 (standard)".
    fast = {
      hf_repo       = "zai-org/GLM-5.3"
      hf_revision   = "aca966e4e02791568aa6a4ced368624b3d897f42"
      license       = "other (see model card)"
      weights_gb    = 756
      machine_type  = "a3-ultragpu-8g"
      max_model_len = 262144
      vllm_args = [
        "--tensor-parallel-size", "8",
        "--kv-cache-dtype", "fp8",
        "--gpu-memory-utilization", "0.92",
        "--speculative-config", "{\"method\": \"mtp\", \"num_speculative_tokens\": 5}",
        "--tool-call-parser", "glm47",
        "--enable-auto-tool-choice",
        "--reasoning-parser", "glm47",
      ]
    }
  }

  validation {
    condition     = alltrue([for k in keys(var.models) : can(regex("^[a-z][a-z0-9-]{0,20}$", k))])
    error_message = "Model keys must be short lowercase names (they become instance names and served model names)."
  }

  validation {
    condition     = alltrue([for m in values(var.models) : can(regex("^[0-9a-f]{40}$", m.hf_revision))])
    error_message = "hf_revision must be a full 40-character Hugging Face commit SHA, not a branch name."
  }

  validation {
    condition = alltrue([for m in values(var.models) : alltrue([
      for a in m.vllm_args : !contains(["--api-key", "--served-model-name", "--port", "--host", "--model", "--max-model-len"], split("=", a)[0])
    ])])
    error_message = "vllm_args must not set --api-key, --served-model-name, --port, --host, --model or --max-model-len; the startup script owns those."
  }
}

# -----------------------------------------------------------------------------
# Runtime image
# -----------------------------------------------------------------------------

variable "vllm_image" {
  description = <<-EOT
    vLLM OpenAI-compatible server image, pinned by tag AND digest. v0.30.0
    (2026-09-22) is the latest release; the recipes require >= 0.25.0 for
    Kimi-K2.6 and DeepSeek-V4-Pro-0813 and >= 0.29.0 for GLM-5.3. The default
    tag is built against CUDA 13.0, which needs NVIDIA driver >= 580 — the
    DLVM image family below ships driver 580.
  EOT
  type        = string
  default     = "vllm/vllm-openai:v0.30.0@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.vllm_image))
    error_message = "vllm_image must be pinned by digest (repo:tag@sha256:...)."
  }
}

variable "boot_image_family" {
  description = "Deep Learning VM image family (NVIDIA driver 580, Docker, NVIDIA container toolkit). Listed on the DLVM image-families page, last updated 2026-09-30."
  type        = string
  default     = "common-cu129-ubuntu-2404-nvidia-580"
}

variable "boot_image_project" {
  description = "Project that publishes boot_image_family."
  type        = string
  default     = "deeplearning-platform-release"
}

# -----------------------------------------------------------------------------
# Capacity and cost guardrails
# -----------------------------------------------------------------------------

variable "provisioning_model" {
  description = <<-EOT
    How GPU capacity is obtained. a3-ultragpu-8g does NOT support plain
    on-demand capacity:
      SPOT        — discounted, preemptible; preemption STOPS the VM.
      FLEX_START  — Dynamic Workload Scheduler; bounded run time (max_run_hours).
      RESERVATION — STANDARD provisioning consuming var.reservation_name.
  EOT
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "FLEX_START", "RESERVATION"], var.provisioning_model)
    error_message = "provisioning_model must be SPOT, FLEX_START or RESERVATION."
  }
}

variable "reservation_name" {
  description = "Specific reservation to consume when provisioning_model = RESERVATION."
  type        = string
  default     = ""
}

variable "idle_shutdown_minutes" {
  description = "Stop a VM after this many minutes with no completed or in-flight requests. 0 disables the idle check (max_run_hours still applies)."
  type        = number
  default     = 20

  validation {
    condition     = var.idle_shutdown_minutes == 0 || (var.idle_shutdown_minutes >= 10 && var.idle_shutdown_minutes <= 240)
    error_message = "idle_shutdown_minutes must be 0 or between 10 and 240."
  }
}

variable "max_run_hours" {
  description = "Hard cap on one run of a VM, regardless of activity. Enforced twice: by the in-guest watchdog, and by Compute Engine (scheduling.max_run_duration = this + 15 minutes)."
  type        = number
  default     = 4

  validation {
    condition     = var.max_run_hours >= 1 && var.max_run_hours <= 24
    error_message = "max_run_hours must be between 1 and 24."
  }
}

variable "startup_timeout_minutes" {
  description = "Stop the VM if vLLM has not answered /metrics this long after boot (weights copy + load + compile). Prevents a crash-looping server from burning GPU hours."
  type        = number
  default     = 75

  validation {
    condition     = var.startup_timeout_minutes >= 20 && var.startup_timeout_minutes <= 180
    error_message = "startup_timeout_minutes must be between 20 and 180."
  }
}

variable "start_on_create" {
  description = <<-EOT
    false (default): a newly created VM prepares itself (waits for the GPU
    driver, pre-pulls the vLLM image to the boot disk) and powers itself off,
    so a deploy leaves every model STOPPED. This replaces
    desired_status = "TERMINATED": the provider's stop call omits
    discardLocalSsd, which the API requires for machine types with local SSD.
  EOT
  type        = bool
  default     = false
}

variable "billing_account_id" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). When set together with monthly_budget_usd, a budget with 50/90/100% alerts is created."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly budget for the project in USD. 0 disables the budget."
  type        = number
  default     = 0
}

variable "budget_alert_emails" {
  description = "Extra e-mail recipients for budget alerts (billing account admins are always notified)."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Access
# -----------------------------------------------------------------------------

variable "iap_tunnel_members" {
  description = "Principals allowed to start/stop the VMs, open IAP tunnels to port 8000 and read the API key, e.g. [\"user:you@example.com\"]."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for m in var.iap_tunnel_members : can(regex("^(user|group|serviceAccount):[^@\\s]+@[^@\\s]+$", m))])
    error_message = "Each member must look like user:<email>, group:<email> or serviceAccount:<email>. Domains and allUsers are not accepted."
  }
}

variable "enable_ssh" {
  description = "Break-glass SSH: also allow IAP to tcp:22 and grant iap_tunnel_members OS Login on the model VMs. Off by default."
  type        = bool
  default     = false
}

variable "runtime_service_account_id" {
  description = "Account ID of the VM runtime service account. bootstrap.sh creates it so the deployer only needs actAs on this one account."
  type        = string
  default     = "devbox-models-runtime"
}

variable "weights_bucket" {
  description = "GCS bucket holding staged weights. Empty means <project_id>-devbox-model-weights (created by bootstrap.sh)."
  type        = string
  default     = ""
}

variable "api_key_version" {
  description = "Bump to rotate the vLLM API key: a new random value is written as a new secret version. VMs pick it up on their next boot."
  type        = string
  default     = "1"
}

variable "subnet_cidr" {
  description = "Primary range of the model subnet."
  type        = string
  default     = "10.80.0.0/24"
}

variable "enable_secure_boot" {
  description = "Shielded VM Secure Boot. Off by default because it only works if the image's NVIDIA kernel modules are signed; vTPM and integrity monitoring are always on."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Extra labels applied to every resource (app=devbox-models is always set)."
  type        = map(string)
  default     = {}
}

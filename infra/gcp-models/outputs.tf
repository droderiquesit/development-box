# =============================================================================
# Outputs — consumed by the DevBox (`ai models up|down|status`) and humans
# =============================================================================

output "models" {
  description = "Per model: instance name, zone, served model name, VM port, suggested localhost port, and the pinned weights."
  value = {
    for k, m in var.models : k => {
      instance_name     = google_compute_instance.model[k].name
      zone              = google_compute_instance.model[k].zone
      served_model_name = k
      port              = local.vllm_port
      local_port        = lookup(local.local_ports, k, null)
      machine_type      = m.machine_type
      hf_repo           = m.hf_repo
      hf_revision       = m.hf_revision
      weights_uri       = "gs://${local.weights_bucket}/${m.hf_repo}/${m.hf_revision}"
    }
  }
}

output "api_key_secret_id" {
  description = "Secret Manager secret holding the vLLM API key (read the `latest` version)."
  value       = google_secret_manager_secret.api_key.secret_id
}

output "weights_bucket" {
  description = "Bucket the VMs copy weights from. Stage a model with stage-weights.sh or the gcp-models workflow (action: stage-weights)."
  value       = local.weights_bucket
}

output "devbox_env" {
  description = "Environment for the DevBox client."
  value = {
    DEVBOX_GCP_PROJECT = var.project_id
    DEVBOX_GCP_ZONE    = var.zone
  }
}

output "iap_tunnel_example" {
  description = "Ready-to-paste commands: start a model, tunnel it to localhost, call it, stop it."
  value       = <<-EOT
    gcloud compute instances start devbox-model-coder --project=${var.project_id} --zone=${var.zone}
    gcloud compute start-iap-tunnel devbox-model-coder ${local.vllm_port} --local-host-port=localhost:18002 --project=${var.project_id} --zone=${var.zone}
    export OPENAI_API_KEY="$(gcloud secrets versions access latest --secret=${google_secret_manager_secret.api_key.secret_id} --project=${var.project_id})"
    curl -s http://localhost:18002/v1/models -H "Authorization: Bearer $OPENAI_API_KEY"
    gcloud compute instances stop devbox-model-coder --discard-local-ssd=true --project=${var.project_id} --zone=${var.zone}
  EOT
}

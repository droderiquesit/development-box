output "agent_urls" {
  description = "Open these in a browser (phone or laptop): Google sign-in, then the dashboard password."
  value       = { for k, s in google_cloud_run_v2_service.agent : k => s.uri }
}

output "image_repository" {
  description = "Push hermes-agent images here, then apply with -var image_digest=sha256:…"
  value       = "${local.registry}/hermes-agent"
}

output "state_bucket" {
  description = "Where each agent's state snapshots live (agents/<name>/)."
  value       = google_storage_bucket.state.name
}

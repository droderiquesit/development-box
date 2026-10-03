# =============================================================================
# Self-hosted open-weight models — network
# =============================================================================
# One dedicated VPC. The VMs have no external IP: inbound reaches them only
# through Identity-Aware Proxy TCP forwarding, outbound goes through Cloud NAT
# (Docker Hub, apt) or Private Google Access (GCS weights, Secret Manager,
# Cloud Logging — which keeps the ~1 TB-per-boot weights copy off NAT billing).

locals {
  name           = "devbox-models"
  weights_bucket = var.weights_bucket != "" ? var.weights_bucket : "${var.project_id}-devbox-model-weights"
  network_tag    = "devbox-model"

  # Google's published source range for IAP TCP forwarding.
  iap_source_range = "35.235.240.0/20"
  vllm_port        = 8000
  iap_ports        = var.enable_ssh ? [tostring(local.vllm_port), "22"] : [tostring(local.vllm_port)]

  # DevBox contract: which localhost port `ai models up` tunnels each key to.
  local_ports = { architect = 18001, coder = 18002, fast = 18003 }

  # Compute Engine's own stop, 15 minutes after the in-guest watchdog's, as a
  # backstop in case the guest is wedged.
  max_run_seconds = var.max_run_hours * 3600 + 900

  # One (model, member) pair per instance-level IAM binding.
  model_members = {
    for pair in setproduct(keys(var.models), var.iap_tunnel_members) :
    "${pair[0]}|${pair[1]}" => { model = pair[0], member = pair[1] }
  }
}

resource "google_compute_network" "models" {
  name                    = local.name
  description             = "Dedicated VPC for the DevBox self-hosted model VMs."
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "models" {
  name                     = "${local.name}-${var.region}"
  network                  = google_compute_network.models.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  # Flow logs: a handful of long-lived flows per boot, so this is cheap.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "models" {
  name    = "${local.name}-router"
  network = google_compute_network.models.id
  region  = var.region
}

resource "google_compute_router_nat" "models" {
  name                               = "${local.name}-nat"
  router                             = google_compute_router.models.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.models.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The ONLY ingress rule: IAP's range to the vLLM port (and 22 when break-glass
# SSH is enabled). Everything else hits the implied deny-all ingress rule.
resource "google_compute_firewall" "iap_ingress" {
  name        = "${local.name}-allow-iap"
  network     = google_compute_network.models.id
  description = "IAP TCP forwarding to the model VMs only."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [local.iap_source_range]
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = local.iap_ports
  }

  log_config {
    metadata = "EXCLUDE_ALL_METADATA"
  }
}

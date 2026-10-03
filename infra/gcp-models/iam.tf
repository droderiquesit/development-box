# =============================================================================
# Identity and access
# =============================================================================
# Runtime service account (created by bootstrap.sh; see variables.tf):
#   project:  roles/logging.logWriter, roles/monitoring.metricWriter
#   secret:   roles/secretmanager.secretAccessor on the ONE API-key secret
#   bucket:   roles/storage.objectViewer on the weights bucket (bootstrap.sh)
#
# iap_tunnel_members:
#   instance: devboxModelsOperator (compute.instances.get/start/stop)
#   instance: roles/iap.tunnelResourceAccessor, conditioned on port 8000
#   project:  devboxModelsLister (compute.instances.list, zoneOperations.get)
#   secret:   roles/secretmanager.secretAccessor (the DevBox reads the key)

data "google_service_account" "runtime" {
  account_id = var.runtime_service_account_id
}

resource "google_project_iam_member" "runtime" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = data.google_service_account.runtime.member
}

# --- Custom roles --------------------------------------------------------------

resource "google_project_iam_custom_role" "operator" {
  role_id     = "devboxModelsOperator"
  title       = "DevBox model VM operator"
  description = "Start, stop and inspect a DevBox model VM. Bound per instance."
  permissions = [
    "compute.instances.get",
    "compute.instances.start",
    "compute.instances.stop",
  ]
}

resource "google_project_iam_custom_role" "lister" {
  role_id     = "devboxModelsLister"
  title       = "DevBox model VM lister"
  description = "List instances and poll zone operations (start/stop wait on these). Neither grants access to any VM."
  permissions = [
    "compute.instances.list",
    "compute.zoneOperations.get",
  ]
}

# --- Human / DevBox principals -------------------------------------------------

resource "google_compute_instance_iam_member" "operator" {
  for_each = local.model_members

  zone          = var.zone
  instance_name = google_compute_instance.model[each.value.model].name
  role          = google_project_iam_custom_role.operator.id
  member        = each.value.member
}

resource "google_project_iam_member" "lister" {
  for_each = toset(var.iap_tunnel_members)

  project = var.project_id
  role    = google_project_iam_custom_role.lister.id
  member  = each.value
}

# Per-instance IAP binding, further limited to the vLLM port (and 22 only when
# enable_ssh). IAP evaluates destination.port for TCP forwarding.
resource "google_iap_tunnel_instance_iam_member" "tunnel" {
  for_each = local.model_members

  zone     = var.zone
  instance = google_compute_instance.model[each.value.model].name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value.member

  condition {
    title       = "devbox-models-ports"
    description = "Only the vLLM port${var.enable_ssh ? " and SSH" : ""}."
    expression  = join(" || ", [for p in local.iap_ports : "destination.port == ${p}"])
  }
}

# --- Break-glass SSH (enable_ssh = true only) --------------------------------

resource "google_compute_instance_iam_member" "os_login" {
  for_each = var.enable_ssh ? local.model_members : {}

  zone          = var.zone
  instance_name = google_compute_instance.model[each.value.model].name
  role          = "roles/compute.osLogin"
  member        = each.value.member
}

# OS Login on a VM that runs as a service account requires actAs on it.
resource "google_service_account_iam_member" "os_login_act_as" {
  for_each = var.enable_ssh ? toset(var.iap_tunnel_members) : toset([])

  service_account_id = data.google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

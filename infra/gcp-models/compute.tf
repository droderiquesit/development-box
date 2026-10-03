# =============================================================================
# Model VMs
# =============================================================================
# One a3-ultragpu-8g (8x H200 141 GB, 32x375 GiB local NVMe SSD attached
# automatically) per model. Each boot: RAID0 the local SSDs at /mnt/models,
# copy the staged weights from GCS, start vLLM in Docker on port 8000. Local
# SSD is discarded on every stop, so the copy runs again on the next boot;
# the boot disk (Docker image cache) persists.

data "google_compute_image" "boot" {
  family  = var.boot_image_family
  project = var.boot_image_project
}

# trivy:ignore:AVD-GCP-0033 No CMEK: the boot disk holds only the OS and a public container image; weights live on local SSD that is discarded on every stop. Google-managed encryption applies.
# trivy:ignore:AVD-GCP-0067 Secure Boot is var.enable_secure_boot (default off): it only works if the image's NVIDIA kernel modules are signed, which is not verified for this DLVM family. vTPM + integrity monitoring stay on.
resource "google_compute_instance" "model" {
  #checkov:skip=CKV_GCP_38:CSEK means storing raw AES keys outside GCP; the boot disk holds only the OS and a public container image (weights are on discarded local SSD), so Google-managed encryption is adequate.
  for_each = var.models

  name         = "devbox-model-${each.key}" # DevBox contract — do not rename.
  description  = "vLLM serving ${each.value.hf_repo}@${substr(each.value.hf_revision, 0, 12)} as '${each.key}'."
  machine_type = each.value.machine_type
  zone         = var.zone
  tags         = [local.network_tag]

  labels = {
    model = each.key
  }

  # Changing these needs a stopped VM; the provider's own stop call omits
  # discardLocalSsd (required for local-SSD machine types), so a human stops
  # the VM first (`gcloud compute instances stop --discard-local-ssd=true`).
  allow_stopping_for_update = false
  deletion_protection       = false

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.boot.self_link
      size  = each.value.boot_disk_gb
      type  = each.value.boot_disk_type # A3 Ultra boots only from hyperdisk-balanced.
      # Pin Hyperdisk Balanced to its included baseline (3000 IOPS, 140 MiB/s)
      # so the idle boot disk is billed for capacity only.
      provisioned_iops       = each.value.boot_disk_type == "hyperdisk-balanced" ? 3000 : null
      provisioned_throughput = each.value.boot_disk_type == "hyperdisk-balanced" ? 140 : null
      labels = {
        app   = "devbox-models"
        model = each.key
      }
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.models.id
    nic_type   = "GVNIC"
    # No access_config block: no external IP. Egress is Cloud NAT.
  }

  service_account {
    email = data.google_service_account.runtime.email
    # Access is governed by the account's IAM roles (see iam.tf); the scope is
    # Google's recommended setting when using least-privilege IAM.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = var.enable_secure_boot
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    provisioning_model          = var.provisioning_model == "RESERVATION" ? "STANDARD" : var.provisioning_model
    preemptible                 = var.provisioning_model == "SPOT"
    automatic_restart           = var.provisioning_model == "RESERVATION"
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = "STOP"

    max_run_duration {
      seconds = local.max_run_seconds
    }

    on_instance_stop_action {
      discard_local_ssd = true
    }
  }

  reservation_affinity {
    type = var.provisioning_model == "RESERVATION" ? "SPECIFIC_RESERVATION" : "NO_RESERVATION"

    dynamic "specific_reservation" {
      for_each = var.provisioning_model == "RESERVATION" ? [var.reservation_name] : []
      content {
        key    = "compute.googleapis.com/reservation-name"
        values = [specific_reservation.value]
      }
    }
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
    # DLVM: make sure the driver named by the image family is installed.
    install-nvidia-driver = "True"
    startup-script = join("\n", [templatefile("${path.module}/templates/startup-env.sh.tftpl", {
      model_key               = each.key
      project_id              = var.project_id
      secret_id               = google_secret_manager_secret.api_key.secret_id
      vllm_image              = var.vllm_image
      vllm_port               = local.vllm_port
      max_model_len           = each.value.max_model_len
      vllm_args_b64           = base64encode(join("\n", each.value.vllm_args))
      vllm_env_b64            = base64encode(join("\n", [for k, v in each.value.env : "${k}=${v}"]))
      weights_uri             = "gs://${local.weights_bucket}/${each.value.hf_repo}/${each.value.hf_revision}"
      idle_shutdown_minutes   = var.idle_shutdown_minutes
      max_run_hours           = var.max_run_hours
      startup_timeout_minutes = var.startup_timeout_minutes
      start_on_create         = var.start_on_create
    }), file("${path.module}/templates/startup.sh")])
  }

  lifecycle {
    # A new DLVM image in the family must not silently replace the VM.
    # Adopt one deliberately with `terraform apply -replace=...` (human).
    ignore_changes = [boot_disk[0].initialize_params[0].image]

    precondition {
      condition     = var.provisioning_model != "RESERVATION" || var.reservation_name != ""
      error_message = "provisioning_model = RESERVATION requires reservation_name."
    }
  }

  # The VM reads the secret and writes logs at first boot.
  depends_on = [
    google_secret_manager_secret_version.api_key,
    google_secret_manager_secret_iam_member.accessor,
    google_project_iam_member.runtime,
    google_compute_router_nat.models,
  ]
}

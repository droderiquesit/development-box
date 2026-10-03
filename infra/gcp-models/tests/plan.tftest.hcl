# Plan-time tests with a mocked google provider: no credentials, no cost.
# Run: terraform init -backend=false && terraform test

mock_provider "google" {
  mock_data "google_service_account" {
    defaults = {
      email  = "devbox-models-runtime@example-proj.iam.gserviceaccount.com"
      member = "serviceAccount:devbox-models-runtime@example-proj.iam.gserviceaccount.com"
      name   = "projects/example-proj/serviceAccounts/devbox-models-runtime@example-proj.iam.gserviceaccount.com"
    }
  }
  mock_data "google_compute_image" {
    defaults = { self_link = "https://www.googleapis.com/compute/v1/projects/deeplearning-platform-release/global/images/x" }
  }
  mock_data "google_project" {
    defaults = { number = "123456789" }
  }
}

variables {
  project_id         = "example-proj"
  iap_tunnel_members = ["user:a@example.com", "group:g@example.com"]
}

run "defaults" {
  command = plan
  assert {
    condition     = length(google_compute_instance.model) == 3
    error_message = "3 instances"
  }
  assert {
    condition     = google_compute_instance.model["coder"].name == "devbox-model-coder"
    error_message = "name contract"
  }
  assert {
    condition     = google_compute_instance.model["coder"].scheduling[0].provisioning_model == "SPOT" && google_compute_instance.model["coder"].scheduling[0].max_run_duration[0].seconds == 15300
    error_message = "spot + max run"
  }
  assert {
    condition     = length(google_iap_tunnel_instance_iam_member.tunnel) == 6 && google_iap_tunnel_instance_iam_member.tunnel["fast|user:a@example.com"].condition[0].expression == "destination.port == 8000"
    error_message = "iap bindings"
  }
  assert {
    condition     = length(google_secret_manager_secret_iam_member.accessor) == 3
    error_message = "secret accessors"
  }
  assert {
    condition     = length(google_billing_budget.models) == 0 && length(google_compute_instance_iam_member.os_login) == 0
    error_message = "optional off"
  }
  assert {
    condition     = output.devbox_env.DEVBOX_GCP_ZONE == "us-central1-b" && output.models["fast"].local_port == 18003
    error_message = "outputs"
  }
  assert {
    condition     = google_compute_firewall.iap_ingress.source_ranges == toset(["35.235.240.0/20"])
    error_message = "fw"
  }
}

run "ssh_budget_reservation" {
  command = plan
  variables {
    enable_ssh          = true
    billing_account_id  = "000000-000000-000000"
    monthly_budget_usd  = 500
    budget_alert_emails = ["x@example.com"]
    provisioning_model  = "RESERVATION"
    reservation_name    = "my-res"
  }
  assert {
    condition     = length(google_billing_budget.models) == 1 && length(google_compute_instance_iam_member.os_login) == 6
    error_message = "budget/ssh"
  }
  assert {
    condition     = google_iap_tunnel_instance_iam_member.tunnel["coder|group:g@example.com"].condition[0].expression == "destination.port == 8000 || destination.port == 22"
    error_message = "ssh cond"
  }
  assert {
    condition     = google_compute_instance.model["architect"].scheduling[0].provisioning_model == "STANDARD" && google_compute_instance.model["architect"].reservation_affinity[0].type == "SPECIFIC_RESERVATION"
    error_message = "reservation"
  }
}

run "reservation_requires_name" {
  command = plan
  variables {
    provisioning_model = "RESERVATION"
  }
  expect_failures = [google_compute_instance.model]
}

run "bad_member" {
  command = plan
  variables {
    iap_tunnel_members = ["allUsers"]
  }
  expect_failures = [var.iap_tunnel_members]
}

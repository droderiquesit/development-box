# =============================================================================
# Billing budget (optional)
# =============================================================================
# Created only when billing_account_id AND monthly_budget_usd are set. A budget
# ALERTS; it does not stop spend. The hard controls are the watchdog
# (idle_shutdown_minutes, max_run_hours) and scheduling.max_run_duration.
#
# The deployer identity needs roles/billing.costsManager on the billing account
# for this (bootstrap.sh grants it when given --billing-account).

locals {
  budget_enabled = var.billing_account_id != "" && var.monthly_budget_usd > 0
}

data "google_project" "this" {
  count      = local.budget_enabled ? 1 : 0
  project_id = var.project_id
}

resource "google_monitoring_notification_channel" "budget_email" {
  for_each = local.budget_enabled ? toset(var.budget_alert_emails) : toset([])

  display_name = "devbox-models budget: ${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }
}

resource "google_billing_budget" "models" {
  count = local.budget_enabled ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "devbox-models ${var.project_id}"

  budget_filter {
    projects        = ["projects/${data.google_project.this[0].number}"]
    calendar_period = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.monthly_budget_usd))
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Early warning on the trajectory, not just the spend to date.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [for c in google_monitoring_notification_channel.budget_email : c.id]
    disable_default_iam_recipients   = false
  }
}

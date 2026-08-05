# =============================================================================
# Observability — one log store, symptom-based alerts
# =============================================================================
# Metrics and dashboards live in Prometheus and Grafana inside the cluster,
# because that stack is free, is where the Airflow and Kubernetes signals
# already are, and replaces a ~EUR 45/month Azure Managed Grafana.
#
# Log Analytics still exists, and is not redundant with it: Azure resource logs
# — Databricks audit events, storage data-plane access, AKS control plane — are
# only available here. Prometheus cannot see them. So the split is by signal
# origin, not by preference:
#
#   in-cluster Prometheus + Grafana   what the workloads emit
#   Log Analytics                     what Azure emits about the resources
#
# Alerts fire on symptoms a user would notice, not on causes. 'Node memory
# above 80 percent' pages someone for a condition the autoscaler is already
# handling; 'gold tables are stale' means a report is wrong right now. See
# ADR-009.
# =============================================================================

locals {
  base_name = "${var.name_prefix}-${var.environment}"
  tags      = merge(var.tags, { component = "observability" })
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # PerGB2018 is the only sane tier below the 100 GB/day commitment point.
  sku               = "PerGB2018"
  retention_in_days = var.retention_days
  daily_quota_gb    = var.daily_quota_gb

  # Query packs and workbooks are shared through Entra, not through a key.
  local_authentication_enabled = false

  tags = local.tags
}

# ── Alert routing ────────────────────────────────────────────────────────────
# One action group per severity class rather than one per alert. An alert that
# needs a new action group is usually an alert that needs a different severity.
resource "azurerm_monitor_action_group" "page" {
  name                = "ag-page-${local.base_name}"
  resource_group_name = var.resource_group_name
  short_name          = substr("pg${var.environment}", 0, 12)
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_action_group" "ticket" {
  name                = "ag-ticket-${local.base_name}"
  resource_group_name = var.resource_group_name
  short_name          = substr("tk${var.environment}", 0, 12)
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_emails
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# ── Diagnostics fan-in ───────────────────────────────────────────────────────
# Every resource passed in sends its logs here. Categories are selected with
# category groups rather than enumerated, so a new log category introduced by
# Azure is captured without a Terraform change — the alternative is silently
# missing the audit events that were added last quarter.
resource "azurerm_monitor_diagnostic_setting" "monitored" {
  for_each = var.monitored_resource_ids

  name                       = "diag-${each.key}"
  target_resource_id         = each.value
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }

  lifecycle {
    # Azure returns categories the resource type does not support as disabled
    # entries, which reads as permanent drift otherwise.
    ignore_changes = [enabled_log, enabled_metric]
  }
}

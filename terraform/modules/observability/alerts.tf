# =============================================================================
# Alerts — symptoms, with a stated owner action for each
# =============================================================================
# Every rule here answers three questions, because a rule that cannot is a rule
# that trains people to ignore the channel:
#
#   What is broken for a user right now?
#   What should the person woken up actually do?
#   Why is this threshold, and not a rounder number?
#
# Severity 1 pages. Severity 2 and 3 raise a ticket and wait for office hours.
# =============================================================================

# ── Databricks job failures ──────────────────────────────────────────────────
# A failed job means a table is not being produced. Downstream that is a stale
# report or a missing data product, which is user-visible.
#
# Threshold of 1 over 15 minutes rather than a rate: at this platform's job
# volume a single failure is already worth looking at, and a percentage would
# need a denominator that changes as domains onboard.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "databricks_job_failure" {
  name                = "alert-dbx-job-failure-${local.base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  severity            = 1
  scopes              = [azurerm_log_analytics_workspace.this.id]
  tags                = local.tags

  description = <<-EOT
    A Databricks job run failed. A table downstream of it is not being
    produced. Check the run's error in the workspace UI, then decide between
    re-running and holding the dependent DAG. Runbook: docs/RUNBOOKS.md#job-failure
  EOT

  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    query                   = <<-KQL
      DatabricksJobs
      | where ActionName in ("runFailed", "runTaskFailed")
      | summarize FailureCount = count() by RequestParams
    KQL
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.page.id]
  }

  # Auto-resolve so a fixed job closes its own alert. Without this, someone has
  # to remember to close it, and the ones nobody closes are the ones that make
  # the next alert easy to dismiss.
  auto_mitigation_enabled = true
}

# ── Unity Catalog access denials ─────────────────────────────────────────────
# Not a reliability signal — a security and onboarding one. A burst of denials
# is either a misconfigured grant blocking a team, or someone probing what they
# can reach. Both need a human, neither needs one at 03:00.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "unity_catalog_denied" {
  name                = "alert-uc-access-denied-${local.base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  severity            = 2
  scopes              = [azurerm_log_analytics_workspace.this.id]
  tags                = local.tags

  description = <<-EOT
    Repeated Unity Catalog permission denials. Either a domain onboarding is
    missing a grant, or a principal is probing catalogs it should not see.
    Identify the principal, then fix the grant or open a security review.
    Runbook: docs/RUNBOOKS.md#access-denied
  EOT

  evaluation_frequency = "PT30M"
  window_duration      = "PT1H"

  criteria {
    query                   = <<-KQL
      DatabricksUnityCatalog
      | extend ResponseJson = parse_json(Response)
      | extend StatusCode = toint(ResponseJson.statusCode)
      | where StatusCode !in (200, 201) or isnotempty(tostring(ResponseJson.errorMessage))
      | summarize DeniedCount = count() by Principal = tostring(parse_json(tostring(Identity)).email)
      | where DeniedCount > 10
    KQL
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ticket.id]
  }

  auto_mitigation_enabled = true
}

# ── Storage authorisation failures ───────────────────────────────────────────
# The lake denies by default at the network layer and grants nothing directly
# to humans. A sustained run of authorisation errors therefore means either a
# workload lost its identity, or something is knocking that should not be.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "storage_auth_failure" {
  name                = "alert-lake-auth-failure-${local.base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  severity            = 2
  scopes              = [azurerm_log_analytics_workspace.this.id]
  tags                = local.tags

  description = <<-EOT
    Sustained authorisation failures against the data lake. Check whether a
    workload identity lost a role assignment before assuming it is hostile —
    a failed apply that removed a grant looks identical from here.
    Runbook: docs/RUNBOOKS.md#lake-auth-failure
  EOT

  evaluation_frequency = "PT15M"
  window_duration      = "PT1H"

  criteria {
    query                   = <<-KQL
      StorageBlobLogs
      | where StatusText has_any ("AuthorizationFailure", "AuthenticationFailed", "AuthorizationPermissionMismatch")
      | summarize FailureCount = count() by CallerIpAddress, AuthenticationType
      | where FailureCount > 25
    KQL
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ticket.id]
  }

  auto_mitigation_enabled = true
}

# ── Meta-monitoring: the cap that can blind us ───────────────────────────────
# daily_quota_gb protects the credit, and its failure mode is that telemetry
# stops while everything looks fine. This rule fires while there is still
# headroom, so the cap is raised or the noisy source is fixed before the
# workspace goes quiet.
#
# 80 percent of the cap, evaluated hourly: enough warning to act within the
# same UTC day, which is the window that matters because the cap resets then.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "ingestion_near_cap" {
  count = var.daily_quota_gb > 0 ? 1 : 0

  name                = "alert-ingest-near-cap-${local.base_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  severity            = 2
  scopes              = [azurerm_log_analytics_workspace.this.id]
  tags                = local.tags

  description = <<-EOT
    Log ingestion has passed 80 percent of the daily cap. When the cap is hit,
    ingestion stops until 00:00 UTC and this platform goes blind. Find the
    noisy source with the Usage table before raising the cap — a log-looping
    pod is the usual cause and raising the cap just pays for it.
    Runbook: docs/RUNBOOKS.md#ingestion-cap
  EOT

  evaluation_frequency = "PT1H"
  window_duration      = "P1D"

  criteria {
    query                   = <<-KQL
      Usage
      | where IsBillable == true
      | summarize IngestedGB = sum(Quantity) / 1000
      | where IngestedGB > ${var.daily_quota_gb * 0.8}
    KQL
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ticket.id]
  }

  auto_mitigation_enabled = true
}

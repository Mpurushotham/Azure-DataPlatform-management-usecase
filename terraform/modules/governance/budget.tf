# =============================================================================
# Budget — an alarm, not a brake
# =============================================================================
# Azure budgets notify. They do not stop spend. Anyone who believes otherwise
# discovers it during the month it matters, so it is stated here rather than
# left implied.
#
# What actually stops spend on this subscription is the Free Trial spending
# limit, and that stops it by disabling services — a platform outage, not a
# cost control. The thresholds below exist to give warning long before that.
#
#   50%  forecast-based, first week    something is running that should not be
#   80%  actual                        act now, park the cluster
#   100% actual                        already over; the credit is finite
#   90%  forecast                      on track to exceed before month end
# =============================================================================

resource "azurerm_consumption_budget_subscription" "platform" {
  name            = "budget-${var.name_prefix}-${var.environment}"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.monthly_budget
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  # Forecast first. By the time actual spend crosses 80 percent there may be
  # two days left in the month; a forecast breach on day four is still
  # actionable.
  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_alert_emails
    contact_groups = var.budget_action_group_ids
  }

  notification {
    enabled        = true
    threshold      = 90
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_alert_emails
    contact_groups = var.budget_action_group_ids
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
    contact_groups = var.budget_action_group_ids
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
    contact_groups = var.budget_action_group_ids
  }
}

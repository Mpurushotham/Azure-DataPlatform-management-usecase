variable "name_prefix" {
  description = "Platform short name used in every policy and budget name."
  type        = string
}

variable "environment" {
  description = "Environment name, part of every resource name and tag."
  type        = string
}

variable "subscription_id" {
  description = "Subscription the policy initiative and budget are assigned to."
  type        = string
}

variable "allowed_locations" {
  description = <<-EOT
    Regions resources may be created in. Sweden Central is the platform's home;
    West Europe stays permitted for the duration of the YODA migration and is
    removed from this list the day the last workload lands. Leaving it in
    afterwards is how a 'temporary' second region becomes permanent.
  EOT
  type        = list(string)
  default     = ["swedencentral", "westeurope"]
}

variable "mandatory_tags" {
  description = <<-EOT
    Tags every resource must carry. Kept short on purpose: each additional
    mandatory tag is a thing that blocks a deployment at 02:00, and a tag
    nobody queries is pure friction. These four are the ones the FinOps report
    and the incident process actually read.
  EOT
  type        = list(string)
  default     = ["platform", "environment", "owner", "cost-center"]
}

variable "tag_policy_effect" {
  description = <<-EOT
    Effect for the mandatory-tag policy.

    Audit in sandbox, Deny in prod. A tag policy set to Deny on day one blocks
    the very deployment that would have created the tagged resources, and the
    resulting scramble teaches people to request exemptions rather than to tag.
    Audit first, fix the gaps the compliance report shows, then flip to Deny.
  EOT
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.tag_policy_effect)
    error_message = "tag_policy_effect must be Audit, Deny or Disabled."
  }
}

variable "security_policy_effect" {
  description = "Effect for the security policies (public access, TLS, Databricks public IP). Deny from the start — these have no legitimate exception on this platform."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.security_policy_effect)
    error_message = "security_policy_effect must be Audit, Deny or Disabled."
  }
}

variable "enforcement_mode" {
  description = "Default enforces the assignment; DoNotEnforce evaluates and reports without blocking. Use DoNotEnforce for a dry run before a Deny rollout."
  type        = string
  default     = "Default"

  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.enforcement_mode)
    error_message = "enforcement_mode must be Default or DoNotEnforce."
  }
}

variable "monthly_budget" {
  description = "Monthly subscription budget in the billing currency. Alerts only — Azure budgets never stop spend by themselves."
  type        = number
  default     = 50
}

variable "budget_action_group_ids" {
  description = "Action groups notified when a budget threshold is crossed."
  type        = list(string)
  default     = []
}

variable "budget_alert_emails" {
  description = "Addresses notified directly on budget thresholds, independent of the action group."
  type        = list(string)
  default     = []
}

variable "budget_start_date" {
  description = "Budget start date, first of a month in RFC3339. Azure rejects a start date in the past on creation, so this is explicit rather than computed."
  type        = string
}

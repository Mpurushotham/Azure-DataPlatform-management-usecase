variable "name_prefix" {
  description = "Platform short name used in every resource name."
  type        = string
}

variable "environment" {
  description = "Environment name, part of every resource name and tag."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group holding the observability stack."
  type        = string
}

variable "retention_days" {
  description = <<-EOT
    Log Analytics retention. Thirty days covers incident investigation and the
    trailing window every dashboard here queries. Compliance retention is a
    different problem solved by archiving to the lake at a twentieth of the
    price — see docs/OBSERVABILITY.md.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.retention_days >= 30 && var.retention_days <= 730
    error_message = "Log Analytics retention must be between 30 and 730 days."
  }
}

variable "daily_quota_gb" {
  description = <<-EOT
    Hard ingestion cap in GB per day. -1 means unlimited.

    A cap is set deliberately, and it is the one control here that can cause an
    outage of the monitoring itself: once hit, ingestion stops until the next
    UTC day. That is the correct trade on a subscription with a spending limit,
    where uncapped ingestion from a log-looping pod can exhaust the credit and
    take down the entire platform rather than just its telemetry.
  EOT
  type        = number
  default     = 1
}

variable "alert_emails" {
  description = "Addresses that receive platform alerts. Empty creates the action group with no receivers, which is valid and silent."
  type        = list(string)
  default     = []
}

variable "monitored_resource_ids" {
  description = "Resource IDs that get a diagnostic setting pointed at this workspace, keyed by a short label."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

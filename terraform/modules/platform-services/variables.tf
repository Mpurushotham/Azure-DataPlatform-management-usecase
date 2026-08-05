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
  description = "Resource group holding the shared platform services."
  type        = string
}

variable "unique_suffix" {
  description = "Short suffix making the globally-unique Key Vault and registry names deterministic per subscription."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant backing the Key Vault."
  type        = string
}

variable "allowed_subnet_ids" {
  description = "Subnets permitted through the Key Vault and registry firewalls."
  type        = list(string)
  default     = []
}

variable "allowed_ip_ranges" {
  description = "Operator source addresses permitted through the firewalls."
  type        = list(string)
  default     = []
}

variable "enable_container_registry" {
  description = "Create the container registry. Basic tier is about EUR 4/month and holds the custom Airflow image."
  type        = bool
  default     = true
}

variable "registry_sku" {
  description = <<-EOT
    Basic, Standard or Premium.

    Private endpoints, geo-replication, content trust and customer-managed keys
    are Premium-only — so a genuinely private registry costs about EUR 45/month
    more than this one. Basic here, with the network ACL doing what it can.
  EOT
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.registry_sku)
    error_message = "registry_sku must be Basic, Standard or Premium."
  }
}

variable "enable_purge_protection" {
  description = <<-EOT
    Key Vault purge protection.

    Off in sandbox and that is deliberate: once enabled it cannot be disabled,
    and a purge-protected vault holds its name for 90 days after deletion. A
    disposable environment that is recreated weekly would run out of names.
    On in prod, where the same property is the point.
  EOT
  type        = bool
  default     = false
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for Key Vault and registry diagnostics."
  type        = string
  default     = ""
}

variable "enable_diagnostics" {
  description = <<-EOT
    Whether to create diagnostic settings.

    A separate boolean rather than a test on log_analytics_workspace_id being
    non-empty, because that ID is produced by another module and is unknown at
    plan time — and `count` cannot depend on an unknown. Terraform's error for
    this suggests -target, which would be the wrong fix for a condition the
    caller already knows the answer to.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

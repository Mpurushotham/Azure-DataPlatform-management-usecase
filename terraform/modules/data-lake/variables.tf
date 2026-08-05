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
  description = "Resource group that holds the lake."
  type        = string
}

variable "unique_suffix" {
  description = "Short suffix making the globally-unique storage account name deterministic per subscription."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,10}$", var.unique_suffix))
    error_message = "unique_suffix must be 4-10 lowercase alphanumeric characters."
  }
}

variable "replication_type" {
  description = <<-EOT
    LRS or ZRS. ZRS survives the loss of one availability zone and is the
    correct choice for a platform whose recovery objective is measured in
    minutes; LRS is roughly 20 percent cheaper and is what a disposable
    environment should use. GRS is deliberately absent — cross-region
    replication for a data lake is handled by Delta deep clone into the paired
    region, not by storage-level replication, because storage replication
    copies corruption as faithfully as it copies data. See docs/DR.md.
  EOT
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS"], var.replication_type)
    error_message = "replication_type must be LRS or ZRS."
  }
}

variable "allowed_subnet_ids" {
  description = "Subnets permitted through the storage firewall. Everything else is denied by default."
  type        = list(string)
  default     = []
}

variable "allowed_ip_ranges" {
  description = "Operator source addresses permitted through the storage firewall, for the initial container seeding that has to happen from a laptop."
  type        = list(string)
  default     = []
}

variable "public_network_access_enabled" {
  description = "Whether the account answers on its public endpoint at all. False requires private endpoints for every consumer, including CI."
  type        = bool
  default     = true
}

variable "enable_private_endpoints" {
  description = "Create dfs and blob private endpoints. Roughly EUR 7 per endpoint per month."
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for private endpoint NICs. Required when enable_private_endpoints is true."
  type        = string
  default     = ""
}

variable "private_dns_zone_ids" {
  description = "Private DNS zone IDs keyed by short name (dfs, blob), from the network module."
  type        = map(string)
  default     = {}
}

variable "enable_versioning" {
  description = "Blob versioning and change feed. Off in sandbox: every version is billed, and a lake full of Parquet accumulates them quickly."
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "Soft-delete window for blobs and containers, in days."
  type        = number
  default     = 7

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 365
    error_message = "retention_days must be between 1 and 365."
  }
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for storage diagnostics. Empty disables the diagnostic setting."
  type        = string
  default     = ""
}

variable "enable_diagnostics" {
  description = "Whether to create diagnostic settings. A plan-time boolean rather than a test on log_analytics_workspace_id, which is produced by another module and unknown at plan time — and `count` cannot depend on an unknown."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

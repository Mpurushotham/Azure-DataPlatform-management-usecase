variable "name_prefix" {
  description = "Platform short name used in every resource name."
  type        = string
}

variable "environment" {
  description = "Environment name, part of every resource name and tag."
  type        = string
}

variable "workspace_key" {
  description = "Short workspace identifier — 'central' for the platform workspace, or the domain name for a domain workspace."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the workspace resource itself. The managed resource group is separate and created by Databricks."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet the workspace is injected into."
  type        = string
}

variable "host_subnet_name" {
  description = "Name of the delegated host (public) subnet for this workspace."
  type        = string
}

variable "container_subnet_name" {
  description = "Name of the delegated container (private) subnet for this workspace."
  type        = string
}

variable "host_subnet_nsg_association_id" {
  description = <<-EOT
    NSG association ID for the host subnet.

    Passed as a value rather than inferred so that Terraform orders the NSG
    association strictly before workspace creation. Databricks validates that
    both injected subnets already carry an NSG; without this dependency the
    apply intermittently fails on a race that only shows up on a clean create.
  EOT
  type        = string
}

variable "container_subnet_nsg_association_id" {
  description = "NSG association ID for the container subnet. Same ordering rationale as the host subnet."
  type        = string
}

variable "public_network_access_enabled" {
  description = <<-EOT
    Whether the workspace UI and REST API answer on the public internet.

    False requires a front-end private endpoint plus a browser-authentication
    private endpoint, and CI must reach the workspace over the VNet. That is
    the production posture. Sandbox leaves it true because the operator reaches
    the workspace from a laptop and there is no VPN into this VNet.
  EOT
  type        = bool
  default     = true
}

variable "enable_private_endpoint" {
  description = "Create the front-end (databricks_ui_api) private endpoint. Roughly EUR 7/month."
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the front-end private endpoint NIC."
  type        = string
  default     = ""
}

variable "private_dns_zone_id" {
  description = "privatelink.azuredatabricks.net zone ID."
  type        = string
  default     = ""
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for Databricks audit diagnostics. Empty disables the diagnostic setting."
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

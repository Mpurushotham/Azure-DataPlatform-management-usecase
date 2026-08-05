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
  description = "Resource group that holds the network."
  type        = string
}

variable "address_space" {
  description = <<-EOT
    VNet CIDR. Sized /16 so the Databricks block, the platform subnets and a
    future second region can all be carved out without renumbering. Renumbering
    a data platform is not a maintenance task, it is a migration.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && tonumber(split("/", var.address_space)[1]) <= 20
    error_message = "address_space must be a valid CIDR of /20 or larger to fit the Databricks block."
  }
}

variable "databricks_workspaces" {
  description = <<-EOT
    Workspace keys that each need a dedicated host/container subnet pair.
    A Databricks workspace cannot share injected subnets with another
    workspace, so this list drives subnet creation directly.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.databricks_workspaces) <= 8
    error_message = "The /20 Databricks block fits 8 workspaces at /24 per subnet. Widen databricks_block_newbits to go further."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Deterministic outbound egress for the Databricks injected subnets.

    Azure retired default outbound access for VNets created after
    30 September 2025, so a classic (VNet-injected) Databricks cluster cannot
    reach the control plane without an explicit egress path. AKS does not need
    this — its Standard Load Balancer provides outbound rules.

    Left off in sandbox because that environment runs serverless Databricks
    compute only, which egresses from Databricks' own network rather than this
    VNet. Turning it on is the single change required before a classic cluster
    can start. Costs roughly EUR 32/month plus data processing.
  EOT
  type        = bool
  default     = false
}

variable "enable_private_endpoint_subnet" {
  description = "Create the Private Link subnet. Off in environments that reach PaaS over service endpoints to avoid ~EUR 7/month per endpoint."
  type        = bool
  default     = true
}

variable "enable_strict_egress" {
  description = <<-EOT
    Append a deny-all outbound rule below the documented Databricks allow rules.

    Off by default because a missing allow rule under a deny-all does not fail
    at apply time — it fails when a cluster silently cannot reach the control
    plane, which is a far worse failure mode to debug. Turn it on with
    enable_nat_gateway, once classic compute is actually in use and egress can
    be observed in flow logs before it is enforced.
  EOT
  type        = bool
  default     = false
}

variable "operator_ip_ranges" {
  description = "Source addresses permitted through default-deny NSG rules for operator access. Empty means no operator ingress at all."
  type        = list(string)
  default     = []
}

variable "enable_private_dns" {
  description = "Create and link the privatelink DNS zones. Follows enable_private_endpoint_subnet in practice — zones without endpoints resolve nothing, endpoints without zones are ignored by clients."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

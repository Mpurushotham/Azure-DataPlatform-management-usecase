variable "name_prefix" {
  description = "Platform short name used in every resource and group name."
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
  description = "Resource group holding the managed identities."
  type        = string
}

variable "domains" {
  description = <<-EOT
    Data domains that each get a reader and a writer group. These groups are
    the only principals ever granted on a Unity Catalog catalog — no user and
    no service principal is granted directly, so access reviews have exactly
    one place to look.
  EOT
  type        = list(string)
  default     = []
}

variable "manage_entra_groups" {
  description = <<-EOT
    Whether this module creates Entra ID groups.

    Creating groups needs a directory role (Groups Administrator), which is
    granted to a human but is a deliberate extra step for the CI identity: a
    pipeline that can mint security groups can mint itself a path to data.
    Set false in CI and pass existing group object IDs via existing_group_ids
    once the groups are established.
  EOT
  type        = bool
  default     = true
}

variable "existing_group_ids" {
  description = "Pre-created Entra group object IDs keyed by logical name, used when manage_entra_groups is false."
  type        = map(string)
  default     = {}
}

variable "platform_admin_object_ids" {
  description = "Object IDs seeded as owners/members of the platform admin group. Usually the humans running the platform."
  type        = list(string)
  default     = []
}

variable "storage_account_id" {
  description = "Data lake storage account ID, scope for the workload data-plane role assignments."
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault ID, scope for secret read grants. Empty skips those assignments."
  type        = string
  default     = ""
}

variable "enable_key_vault_grant" {
  description = "Grant the Airflow identity Key Vault Secrets User on key_vault_id. Separate from key_vault_id being non-empty for the same plan-time reason as enable_diagnostics elsewhere."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "domain" {
  description = "Data domain this catalog serves. 'platform' for the central workspace."
  type        = string
}

variable "name_prefix" {
  description = "Platform short name, prefixed to the catalog name."
  type        = string
}

variable "environment" {
  description = "Environment name, part of the catalog name so sandbox and prod catalogs never collide in a shared metastore."
  type        = string
}

variable "access_connector_id" {
  description = "Databricks Access Connector resource ID backing the storage credential."
  type        = string
}

variable "storage_account_id" {
  description = "Data lake storage account ID, scope for the Access Connector's data-plane role assignment."
  type        = string
}

variable "access_connector_principal_id" {
  description = "Managed identity object ID of the Access Connector, granted on the lake."
  type        = string
}

variable "external_locations" {
  description = <<-EOT
    abfss:// URLs this catalog may reach, keyed by medallion layer. Each becomes
    a Unity Catalog external location, which is the object a grant is written
    against — a path not registered here is unreachable regardless of what the
    storage RBAC says.
  EOT
  type        = map(string)
}

variable "catalog_storage_layer" {
  description = "Which external location backs the catalog's managed tables. Managed tables land here when a job does not specify a path."
  type        = string
  default     = "silver"
}

variable "schemas" {
  description = "Schemas created inside the catalog, with the comment that appears in the data catalogue UI."
  type        = map(string)
  default = {
    bronze = "Raw history, append-only, schema-on-read."
    silver = "Cleansed, conformed and deduplicated entities."
    gold   = "Business-level aggregates serving reporting and data products."
  }
}

variable "reader_principal" {
  description = "Entra group display name granted read access. Must already exist in Databricks via SCIM. Empty skips the grant."
  type        = string
  default     = ""
}

variable "writer_principal" {
  description = "Entra group display name granted write access. Must already exist in Databricks via SCIM. Empty skips the grant."
  type        = string
  default     = ""
}

variable "owner_principal" {
  description = "Entra group display name that owns the catalog. Empty leaves ownership with the creating principal."
  type        = string
  default     = ""
}

variable "enable_grants" {
  description = <<-EOT
    Whether to apply Unity Catalog grants.

    Off until SCIM provisioning has synchronised the Entra groups into the
    Databricks account. A grant naming a principal Databricks has never seen
    fails the apply, and the failure is confusing because the group plainly
    exists in Entra. See docs/RUNBOOKS.md#scim-provisioning.
  EOT
  type        = bool
  default     = false
}

variable "isolation_mode" {
  description = "ISOLATED binds the credential and locations to this workspace only; OPEN shares them across every workspace on the metastore."
  type        = string
  default     = "ISOLATED"

  validation {
    condition     = contains(["ISOLATED", "OPEN"], var.isolation_mode)
    error_message = "isolation_mode must be ISOLATED or OPEN."
  }
}

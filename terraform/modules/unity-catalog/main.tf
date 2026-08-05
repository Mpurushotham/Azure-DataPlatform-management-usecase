# =============================================================================
# Unity Catalog — one catalog per domain, groups as the only principal
# =============================================================================
# The access chain, and why it has this many links:
#
#   Access Connector (managed identity)
#     -> Storage Blob Data Contributor on the lake     Azure RBAC
#     -> databricks_storage_credential                 UC wraps the identity
#     -> databricks_external_location                  UC names a path
#     -> databricks_catalog / schema                   UC names the data
#     -> databricks_grants to an Entra group           UC decides who
#
# No human and no job holds a role on the storage account. Every read is
# authorised by Unity Catalog and recorded in its audit log, which is what makes
# "who read this table" a question with an answer.
#
# This module assumes a metastore already exists in the region and is assigned
# to the workspace. Azure Databricks auto-provisions one per region on first
# workspace creation, and creating one explicitly needs account-admin
# credentials that a workspace-scoped provider does not have. The check is in
# scripts/bash/check-metastore.sh and the reasoning is in ADR-007.
# =============================================================================

locals {
  catalog_name = replace("${var.name_prefix}_${var.environment}_${var.domain}", "-", "_")

  # Unity Catalog spells isolation_mode two different ways depending on the
  # object, and the API returns the long form on read. Setting the short form on
  # a credential produces a permanent diff that then fails to apply, because
  # updating a credential with dependent locations needs force_update.
  #
  #   storage credential, external location   ISOLATION_MODE_ISOLATED / _OPEN
  #   catalog                                 ISOLATED / OPEN
  #
  # One variable, mapped here, so callers never have to know.
  credential_isolation_mode = var.isolation_mode == "ISOLATED" ? "ISOLATION_MODE_ISOLATED" : "ISOLATION_MODE_OPEN"
}

# The Access Connector's identity needs data-plane access to the lake before
# Unity Catalog can validate the storage credential. Contributor rather than
# Reader: Unity Catalog writes managed tables, and it verifies write access at
# credential-creation time by attempting one.
resource "azurerm_role_assignment" "access_connector_lake" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.access_connector_principal_id

  description = "Unity Catalog data-plane access for the ${var.domain} domain. The only principal with write access to the lake."
}

resource "databricks_storage_credential" "this" {
  name    = "sc-${var.name_prefix}-${var.environment}-${var.domain}"
  comment = "Managed identity credential for the ${var.domain} domain. Backed by the workspace Access Connector."

  azure_managed_identity {
    access_connector_id = var.access_connector_id
  }

  # ISOLATED keeps the credential usable only from the workspace that owns it.
  # An OPEN credential on a shared metastore means any workspace can assume the
  # domain's storage identity, which defeats the per-domain boundary the
  # workspace split exists to create.
  isolation_mode = local.credential_isolation_mode

  # Required to change anything on a credential that already has dependent
  # external locations. Without it, every subsequent apply fails on a diff it
  # cannot resolve — including the first one, because Databricks creates the
  # credential OPEN and this config asks for ISOLATED.
  force_update = true

  # Azure RBAC is eventually consistent — the credential validates by touching
  # storage, and without this the first apply fails on a role assignment that
  # exists but has not propagated.
  depends_on = [azurerm_role_assignment.access_connector_lake]
}

resource "databricks_external_location" "this" {
  for_each = var.external_locations

  name            = "el-${var.name_prefix}-${var.environment}-${var.domain}-${each.key}"
  url             = each.value
  credential_name = databricks_storage_credential.this.name
  comment         = "${title(each.key)} layer for the ${var.domain} domain."
  isolation_mode  = local.credential_isolation_mode

  # Without this, destroying the location while tables still reference it
  # leaves those tables unreadable rather than failing loudly.
  force_destroy = false
}

resource "databricks_catalog" "this" {
  name    = local.catalog_name
  comment = "Data products and pipeline output for the ${var.domain} domain (${var.environment})."

  storage_root = databricks_external_location.this[var.catalog_storage_layer].url

  properties = {
    domain      = var.domain
    environment = var.environment
    managed-by  = "terraform"
  }

  # Bound to the owning workspace. A catalog left OPEN is visible from every
  # workspace on the metastore, which turns the data-mesh boundary into a
  # naming convention.
  isolation_mode = var.isolation_mode

  owner = var.owner_principal != "" ? var.owner_principal : null

  force_destroy = false

  depends_on = [databricks_external_location.this]
}

resource "databricks_schema" "this" {
  for_each = var.schemas

  catalog_name = databricks_catalog.this.name
  name         = each.key
  comment      = each.value

  properties = {
    domain     = var.domain
    managed-by = "terraform"
  }

  force_destroy = false
}

# =============================================================================
# Unity Catalog and compute policy, per workspace
# =============================================================================
# The central workspace owns platform-wide assets; each domain workspace owns
# exactly one catalog. The pairing is one-to-one and deliberate — a workspace
# with two catalogs has an internal boundary that nothing enforces.
#
# Adding a domain means: append it to `domains` in the sandbox root, apply
# that, then add a provider alias and two module blocks here. That is more
# ceremony than a for_each, and it is the ceremony Terraform's provider model
# requires. docs/ONBOARDING-DOMAIN.md walks through it.
# =============================================================================

data "terraform_remote_state" "sandbox" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.state_resource_group_name
    storage_account_name = var.state_storage_account_name
    container_name       = var.state_container_name
    key                  = var.state_key
    use_azuread_auth     = true
  }
}

locals {
  sandbox     = data.terraform_remote_state.sandbox.outputs
  lake_urls   = local.sandbox.lake_container_urls
  group_names = local.sandbox.entra_group_names

  # Layers a domain catalog registers as external locations. `landing` is
  # excluded on purpose: it holds raw source drops that no catalog should be
  # able to query directly, and the ingest job reaches it with the Airflow
  # identity instead.
  layers = ["bronze", "silver", "gold"]

  # Each domain owns a prefix *inside* each medallion container, never the
  # container root.
  #
  # This is a hard Unity Catalog constraint, not a style preference: external
  # locations are metastore-scoped and may not overlap. Registering
  # abfss://silver@lake/ for two domains fails the second one with
  # "overlaps with an existing external location" — and had it succeeded, both
  # domains would have been granted the whole silver layer, which is precisely
  # the isolation the per-domain workspace split exists to create.
  #
  #   abfss://silver@lake/platform/     central workspace only
  #   abfss://silver@lake/logistics/    logistics workspace only
  domain_layers = {
    for domain in ["platform", "logistics"] : domain => {
      for layer in local.layers : layer => "${local.lake_urls[layer]}${domain}/"
    }
  }

  # Ownership and grants both name Databricks principals, which only exist once
  # SCIM has synchronised the Entra groups into the account. Setting an owner
  # before that fails with "Could not find principal", so both follow the same
  # switch rather than only the grants.
  owner = var.enable_grants ? local.group_names["platform-admins"] : ""
}

# ── Central platform workspace ───────────────────────────────────────────────
# Holds the platform catalog: shared reference data, data-quality results, and
# the operational tables the FinOps and drift reports write into.
module "uc_central" {
  source = "../../modules/unity-catalog"

  providers = {
    databricks = databricks.central
  }

  domain      = "platform"
  name_prefix = "yoda"
  environment = "sandbox"

  access_connector_id           = local.sandbox.databricks_workspaces["central"].access_connector_id
  access_connector_principal_id = local.sandbox.databricks_workspaces["central"].access_connector_principal_id
  storage_account_id            = local.sandbox.storage_account_id

  external_locations    = local.domain_layers["platform"]
  catalog_storage_layer = "silver"

  owner_principal  = local.owner
  writer_principal = local.group_names["data-engineers"]
  reader_principal = local.group_names["data-analysts"]
  enable_grants    = var.enable_grants

  isolation_mode = "ISOLATED"
}

module "compute_central" {
  source = "../../modules/databricks-compute"

  providers = {
    databricks = databricks.central
  }

  name_prefix = "yoda"
  environment = "sandbox"
  domain      = "platform"
  cost_center = "data-platform"

  enable_sql_warehouse = var.enable_sql_warehouse
}

# ── Logistics domain workspace ───────────────────────────────────────────────
module "uc_logistics" {
  source = "../../modules/unity-catalog"

  providers = {
    databricks = databricks.logistics
  }

  domain      = "logistics"
  name_prefix = "yoda"
  environment = "sandbox"

  access_connector_id           = local.sandbox.databricks_workspaces["logistics"].access_connector_id
  access_connector_principal_id = local.sandbox.databricks_workspaces["logistics"].access_connector_principal_id
  storage_account_id            = local.sandbox.storage_account_id

  external_locations    = local.domain_layers["logistics"]
  catalog_storage_layer = "silver"

  owner_principal  = local.owner
  writer_principal = local.group_names["domain-logistics-writers"]
  reader_principal = local.group_names["domain-logistics-readers"]
  enable_grants    = var.enable_grants

  isolation_mode = "ISOLATED"
}

module "compute_logistics" {
  source = "../../modules/databricks-compute"

  providers = {
    databricks = databricks.logistics
  }

  name_prefix = "yoda"
  environment = "sandbox"
  domain      = "logistics"
  cost_center = "logistics"

  enable_sql_warehouse = var.enable_sql_warehouse
}

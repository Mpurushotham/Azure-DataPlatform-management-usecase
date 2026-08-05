# =============================================================================
# Databricks workspace — VNet-injected, Secure Cluster Connectivity, Premium
# =============================================================================
# One instance of this module per workspace. The hub-and-spoke shape it builds:
#
#   central     the platform workspace. Owns the metastore configuration,
#               cluster policies and the jobs that maintain shared assets.
#   <domain>    one per data domain. Its own catalog, its own compute, its own
#               cost attribution, its own injected subnets.
#
# The alternative — one workspace with catalogs for isolation — was rejected
# because a workspace is the boundary for cluster policies, workspace admins,
# and the DBU line on the bill. Domains that share a workspace share all three,
# and 'who spent this' becomes unanswerable. See ADR-006.
#
# Three settings here cannot be changed after creation. Getting them wrong
# means recreating the workspace, which means re-registering every external
# location and re-pointing every job:
#
#   sku = premium              Unity Catalog, cluster policies, audit logs
#   no_public_ip = true        Secure Cluster Connectivity
#   VNet injection             the subnets themselves
# =============================================================================

locals {
  base_name      = "${var.name_prefix}-${var.environment}"
  workspace_name = "dbw-${local.base_name}-${var.workspace_key}"

  tags = merge(var.tags, {
    component = "databricks"
    workspace = var.workspace_key
  })
}

resource "azurerm_databricks_workspace" "this" {
  name                = local.workspace_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Premium is not an upsell here. Unity Catalog, cluster policies, table ACLs,
  # audit log delivery and SCIM all require it, and every one of them is load
  # bearing in this design.
  sku = "premium"

  # Databricks creates and owns this resource group: the DBFS root storage
  # account, the managed VNet artefacts and the access connector for the
  # workspace live in it. Named explicitly so it is recognisable in the bill
  # rather than appearing as databricks-rg-<random>.
  managed_resource_group_name = "rg-${local.base_name}-${var.workspace_key}-dbx-managed"

  public_network_access_enabled = var.public_network_access_enabled

  # Required for VNet injection: Databricks needs to know an NSG is present so
  # it can add its worker-to-worker rules rather than manage the subnet itself.
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    no_public_ip = true

    virtual_network_id  = var.virtual_network_id
    public_subnet_name  = var.host_subnet_name
    private_subnet_name = var.container_subnet_name

    public_subnet_network_security_group_association_id  = var.host_subnet_nsg_association_id
    private_subnet_network_security_group_association_id = var.container_subnet_nsg_association_id
  }

  tags = local.tags

  lifecycle {
    # Databricks writes back internal values on these after creation, and the
    # managed resource group ID is generated. Neither is a change anyone made.
    ignore_changes = [
      custom_parameters[0].storage_account_name,
      custom_parameters[0].storage_account_sku_name,
    ]
  }
}

# ── Access Connector ─────────────────────────────────────────────────────────
# Unity Catalog reaches ADLS through this managed identity, never through a
# key or a service principal secret. It is the storage credential the metastore
# is configured with, and it is the only principal with write access to the
# managed-table root.
#
# One per workspace rather than one shared: a per-workspace connector means a
# domain's storage credential can be revoked without touching any other domain.
resource "azurerm_databricks_access_connector" "this" {
  name                = "dbac-${local.base_name}-${var.workspace_key}"
  resource_group_name = var.resource_group_name
  location            = var.location

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# ── Front-end private endpoint ───────────────────────────────────────────────
# Puts the workspace UI and REST API on a VNet address. Note this is only half
# of a fully private workspace: a browser_authentication endpoint is also
# required for Entra sign-in to complete when public access is disabled, and
# that endpoint belongs to the region rather than the workspace. It is created
# in the environment root, not here, because a second workspace must not create
# a second one.
resource "azurerm_private_endpoint" "ui_api" {
  count = var.enable_private_endpoint ? 1 : 0

  name                = "pe-${local.workspace_name}-uiapi"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.workspace_name}-uiapi"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdz-databricks"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

# ── Audit diagnostics ────────────────────────────────────────────────────────
# Databricks audit logs are the record of who read what. They are not available
# anywhere else — not in the workspace UI beyond a short window, and not in
# Prometheus — so this setting is what makes an access review possible at all.
resource "azurerm_monitor_diagnostic_setting" "workspace" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-${local.workspace_name}"
  target_resource_id         = azurerm_databricks_workspace.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Enumerated rather than a category group. Databricks exposes around twenty
  # categories and most are high-volume operational noise; on a 1 GB/day cap,
  # 'all' would exhaust the quota before lunch and blind the platform. These
  # five are the ones an audit or an incident actually reads.
  enabled_log {
    category = "accounts"
  }

  enabled_log {
    category = "unityCatalog"
  }

  enabled_log {
    category = "clusters"
  }

  enabled_log {
    category = "jobs"
  }

  enabled_log {
    category = "secrets"
  }
}

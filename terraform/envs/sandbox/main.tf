# =============================================================================
# Environment: sandbox — the platform as actually deployed
# =============================================================================
# A real deployment on a Free Trial subscription with a 4 vCPU regional quota
# and a spending limit that disables services rather than billing for them.
# The constraint is not incidental; it is what the design has to survive, and
# it produces a platform that is honest about what costs money.
#
# The vCPU budget in full:
#
#   AKS system pool   1-2 x Standard_B2s_v2   2-4 vCPU
#   Databricks        serverless only              0 vCPU
#   ------------------------------------------------------
#   ceiling                                        4 vCPU
#
# Databricks serverless compute runs in Databricks' own subscription, so it
# consumes none of this quota. That single choice is what lets a data platform
# and a Kubernetes cluster coexist inside four cores.
#
# Disabled here, and what each one would cost:
#
#   what                        why it is off                    ~EUR/month
#   --------------------------  -------------------------------  ----------
#   Private endpoints           storage firewall + service          ~7 each
#                               endpoints give the isolation
#   Private DNS zones           nothing to resolve without the      ~0.5 each
#                               endpoints
#   NAT gateway                 serverless Databricks does not      ~32
#                               egress through this VNet
#   Azure Managed Grafana       Grafana OSS runs in-cluster         ~45
#   Container Insights          Prometheus already collects it      per GB
#   AKS Standard tier           no SLA needed on a lab              ~65
#   Postgres Flexible Server    in-cluster Postgres on a PVC        ~13
#   Key Vault purge protection  irreversible; blocks name reuse     0
#
# Not disabled, because they are the platform rather than decoration: Unity
# Catalog, Secure Cluster Connectivity, VNet injection, workload identity
# federation, Entra-only storage auth, default-deny NSGs, cluster policies,
# Azure Policy, audit diagnostics and the budget.
#
# Teardown is expected: `make destroy ENV=sandbox`.
# =============================================================================

locals {
  environment = "sandbox"
  name_prefix = "yoda"

  # Every workspace that needs an injected subnet pair. 'central' is the
  # platform workspace; the rest are domains.
  databricks_workspaces = concat(["central"], var.domains)

  common_tags = {
    platform    = local.name_prefix
    environment = local.environment
    owner       = "data-platform-team"
    cost-center = "data-platform"
    managed-by  = "terraform"
  }
}

# ── Resource groups ──────────────────────────────────────────────────────────
# Split by lifecycle and blast radius rather than by team. The network outlives
# the compute; the lake outlives both. A single resource group would mean one
# accidental delete takes the data with it.
resource "azurerm_resource_group" "network" {
  name     = "rg-${local.name_prefix}-${local.environment}-network"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "data" {
  name     = "rg-${local.name_prefix}-${local.environment}-data"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "databricks" {
  name     = "rg-${local.name_prefix}-${local.environment}-databricks"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "compute" {
  name     = "rg-${local.name_prefix}-${local.environment}-compute"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "observability" {
  name     = "rg-${local.name_prefix}-${local.environment}-observability"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "security" {
  name     = "rg-${local.name_prefix}-${local.environment}-security"
  location = var.location
  tags     = local.common_tags
}

# ── Observability first ──────────────────────────────────────────────────────
# Created before everything else so that every other module can point its
# diagnostic settings at the workspace as it is created, rather than in a
# second pass that someone forgets to run.
module "observability" {
  source = "../../modules/observability"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.observability.name

  retention_days = 30
  daily_quota_gb = 1
  alert_emails   = var.budget_alert_emails

  tags = local.common_tags
}

# ── Network ──────────────────────────────────────────────────────────────────
module "network" {
  source = "../../modules/network"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name

  address_space         = "10.60.0.0/16"
  databricks_workspaces = local.databricks_workspaces

  # All three off: see the cost table in the header. Each is a single tfvar
  # away from on, and prod turns all three on.
  enable_nat_gateway             = false
  enable_private_endpoint_subnet = false
  enable_private_dns             = false
  enable_strict_egress           = false

  operator_ip_ranges = var.operator_ip_ranges

  tags = local.common_tags
}

# ── Data lake ────────────────────────────────────────────────────────────────
module "data_lake" {
  source = "../../modules/data-lake"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.data.name
  unique_suffix       = var.unique_suffix

  replication_type = "LRS"

  # The storage firewall is the isolation boundary in this environment. The
  # Databricks injected subnets and the AKS subnet carry Microsoft.Storage
  # service endpoints, so they reach the lake over the Azure backbone without
  # a private endpoint.
  allowed_subnet_ids = concat(
    [module.network.platform_subnet_id],
    [for ws in local.databricks_workspaces : module.network.databricks_subnet_ids[ws].host],
    [for ws in local.databricks_workspaces : module.network.databricks_subnet_ids[ws].container],
  )
  allowed_ip_ranges = var.operator_ip_ranges

  public_network_access_enabled = true
  enable_private_endpoints      = false
  enable_versioning             = false
  retention_days                = 7

  log_analytics_workspace_id = module.observability.workspace_id

  tags = local.common_tags
}

# ── Platform services ────────────────────────────────────────────────────────
module "platform_services" {
  source = "../../modules/platform-services"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.security.name
  unique_suffix       = var.unique_suffix
  tenant_id           = var.tenant_id

  allowed_subnet_ids = [module.network.platform_subnet_id]
  allowed_ip_ranges  = var.operator_ip_ranges

  enable_container_registry = true
  registry_sku              = "Basic"
  enable_purge_protection   = false

  log_analytics_workspace_id = module.observability.workspace_id

  tags = local.common_tags
}

# ── Identity ─────────────────────────────────────────────────────────────────
module "identity" {
  source = "../../modules/identity"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.security.name

  domains                   = var.domains
  manage_entra_groups       = true
  platform_admin_object_ids = var.platform_admin_object_ids

  storage_account_id     = module.data_lake.storage_account_id
  key_vault_id           = module.platform_services.key_vault_id
  enable_key_vault_grant = true

  tags = local.common_tags
}

# ── Databricks workspaces ────────────────────────────────────────────────────
# One per entry in local.databricks_workspaces. Unity Catalog, cluster policies
# and the SQL warehouse are configured by the sandbox-databricks root, which
# cannot live here: the databricks provider needs a workspace URL that does not
# exist until these resources are applied. See ADR-008.
module "databricks" {
  source   = "../../modules/databricks-workspace"
  for_each = toset(local.databricks_workspaces)

  name_prefix         = local.name_prefix
  environment         = local.environment
  workspace_key       = each.value
  location            = var.location
  resource_group_name = azurerm_resource_group.databricks.name

  virtual_network_id    = module.network.vnet_id
  host_subnet_name      = module.network.databricks_subnet_ids[each.value].host_name
  container_subnet_name = module.network.databricks_subnet_ids[each.value].container_name

  host_subnet_nsg_association_id      = module.network.databricks_nsg_association_ids[each.value].host
  container_subnet_nsg_association_id = module.network.databricks_nsg_association_ids[each.value].container

  public_network_access_enabled = true
  enable_private_endpoint       = false

  log_analytics_workspace_id = module.observability.workspace_id

  tags = local.common_tags
}

# ── Governance ───────────────────────────────────────────────────────────────
module "governance" {
  source = "../../modules/governance"

  name_prefix     = local.name_prefix
  environment     = local.environment
  subscription_id = var.subscription_id

  # West Europe stays allowed while the YODA migration is in flight. It comes
  # out of this list the day the last workload lands in Sweden Central.
  allowed_locations = ["swedencentral", "westeurope"]

  # Audit, not Deny. Flipping to Deny before the compliance report is clean
  # blocks the next apply on a resource type that does not accept tags, and
  # teaches the team to request exemptions. See the variable's own note.
  tag_policy_effect      = "Audit"
  security_policy_effect = "Deny"
  enforcement_mode       = "Default"

  monthly_budget          = var.monthly_budget
  budget_start_date       = var.budget_start_date
  budget_alert_emails     = var.budget_alert_emails
  budget_action_group_ids = [module.observability.action_group_ticket_id]
}

# ── AKS ──────────────────────────────────────────────────────────────────────
module "aks" {
  source = "../../modules/aks-platform"
  count  = var.enable_aks ? 1 : 0

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.compute.name

  subnet_id = module.network.platform_subnet_id

  sku_tier       = "Free"
  node_vm_size   = "Standard_B2s_v2"
  node_count_min = 1
  node_count_max = 2

  api_server_authorized_ip_ranges = var.operator_ip_ranges
  admin_group_object_ids = compact([
    lookup(module.identity.group_object_ids, "platform-admins", "")
  ])

  acr_id                     = module.platform_services.registry_id
  enable_acr_pull            = true
  log_analytics_workspace_id = module.observability.workspace_id
  enable_container_insights  = false

  # Airflow federates into its own identity, bound to exactly one
  # ServiceAccount in one namespace.
  workload_identities = {
    airflow = {
      identity_resource_group = azurerm_resource_group.security.name
      identity_name           = module.identity.airflow_identity_name
      namespace               = "airflow"
      service_account         = "airflow"
    }
  }

  tags = local.common_tags
}

# =============================================================================
# Environment: prod — the reference posture, deliberately not applied here
# =============================================================================
# Same module set as sandbox. Every difference below is a setting a Free Trial
# subscription cannot fund, kept in code rather than in prose so it is reviewed,
# linted and scanned like everything else — see ADR-002.
#
# What changes from sandbox, and what each one costs:
#
#   private endpoints + DNS      unreachable public endpoints      ~EUR 40/mo
#   NAT gateway + strict egress  deterministic, controlled egress  ~EUR 32/mo
#   ZRS storage                  survives an availability zone     ~+20% storage
#   blob versioning              recovery from a bad overwrite     per version
#   AKS Standard tier            uptime SLA                        ~EUR 65/mo
#   3 node pools                 workload isolation                24 vCPU
#   Postgres Flexible Server     Airflow history survives rebuild  ~EUR 13/mo
#   purge protection             a vault that cannot be destroyed  0
#   Container Insights           pod-level logs in Log Analytics   per GB
#   tag policy = Deny            untagged resources blocked        0
#
# This root has never been applied. Its first apply will find problems — that is
# the honest cost of ADR-002 and is recorded there rather than glossed here.
#
# Before applying: `./scripts/bash/check-quota.sh prod` — this needs 24 vCPU.
# =============================================================================

locals {
  environment = "prod"
  name_prefix = "yoda"

  databricks_workspaces = concat(["central"], var.domains)

  common_tags = {
    platform    = local.name_prefix
    environment = local.environment
    owner       = "data-platform-team"
    cost-center = "data-platform"
    managed-by  = "terraform"
    criticality = "high"
  }
}

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

module "observability" {
  source = "../../modules/observability"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.observability.name

  # 90 days, and no ingestion cap. In production, losing telemetry to a cap is a
  # worse outcome than the bill — the opposite of the sandbox trade.
  retention_days = 90
  daily_quota_gb = -1
  alert_emails   = var.budget_alert_emails

  tags = local.common_tags
}

module "network" {
  source = "../../modules/network"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name

  # A different /16 from sandbox so the two can peer without renumbering.
  address_space         = "10.70.0.0/16"
  databricks_workspaces = local.databricks_workspaces

  enable_nat_gateway             = true
  enable_private_endpoint_subnet = true
  enable_private_dns             = true

  # A missing allow rule under a deny-all does not fail at apply — it fails when
  # a cluster cannot reach its control plane, which surfaces as a launch
  # timeout. NSG flow logs are the correct way to observe real egress before
  # enforcing, and they are NOT implemented in this repository (see
  # docs/NETWORK-CIA.md). Until they are, treat this as a setting to enable
  # deliberately after a period of observation, not one to inherit from here.
  enable_strict_egress = true

  operator_ip_ranges = var.operator_ip_ranges

  tags = local.common_tags
}

module "data_lake" {
  source = "../../modules/data-lake"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.data.name
  unique_suffix       = var.unique_suffix

  # Zone-redundant. Cross-region protection is Delta DEEP CLONE into Sweden
  # South, not GRS — storage replication copies corruption as faithfully as it
  # copies data. See docs/DR.md.
  replication_type = "ZRS"

  # Unreachable except through a private endpoint. This is the setting sandbox
  # cannot have, and the reason the endpoints exist.
  public_network_access_enabled = false
  enable_private_endpoints      = true
  private_endpoint_subnet_id    = module.network.private_endpoint_subnet_id
  private_dns_zone_ids          = module.network.private_dns_zone_ids

  allowed_subnet_ids = concat(
    [module.network.platform_subnet_id],
    [for ws in local.databricks_workspaces : module.network.databricks_subnet_ids[ws].host],
    [for ws in local.databricks_workspaces : module.network.databricks_subnet_ids[ws].container],
  )

  enable_versioning = true
  retention_days    = 30

  log_analytics_workspace_id = module.observability.workspace_id

  tags = local.common_tags
}

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

  # Premium buys private endpoints, geo-replication, content trust and image
  # retention — the last of which removes the manual pruning sandbox needs.
  enable_container_registry = true
  registry_sku              = "Premium"

  # Irreversible, and that is the point in production.
  enable_purge_protection = true

  log_analytics_workspace_id = module.observability.workspace_id

  tags = local.common_tags
}

module "identity" {
  source = "../../modules/identity"

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.security.name

  domains = var.domains

  # False in production: a pipeline that can mint security groups can mint
  # itself a path to data. The groups are created once by a human with the
  # directory role and passed in by object ID thereafter.
  manage_entra_groups       = false
  existing_group_ids        = var.existing_group_ids
  platform_admin_object_ids = var.platform_admin_object_ids

  storage_account_id     = module.data_lake.storage_account_id
  key_vault_id           = module.platform_services.key_vault_id
  enable_key_vault_grant = true

  tags = local.common_tags
}

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

  # Front-end private endpoint per workspace. Note this is only half of a fully
  # private workspace — a regional browser_authentication endpoint is also
  # required for Entra sign-in to complete, and belongs at the environment level
  # rather than per workspace.
  public_network_access_enabled = false
  enable_private_endpoint       = true
  private_endpoint_subnet_id    = module.network.private_endpoint_subnet_id
  private_dns_zone_id           = module.network.private_dns_zone_ids["databricks"]

  log_analytics_workspace_id = module.observability.workspace_id

  tags = local.common_tags
}

module "governance" {
  source = "../../modules/governance"

  name_prefix     = local.name_prefix
  environment     = local.environment
  subscription_id = var.subscription_id

  # West Europe is absent. Removing it is the step that makes the YODA
  # migration irreversible — see docs/MIGRATION-YODA.md phase 7.
  allowed_locations = ["swedencentral"]

  # Deny, not Audit. By production the compliance report is clean, so the policy
  # blocks new violations rather than counting them.
  tag_policy_effect      = "Deny"
  security_policy_effect = "Deny"
  enforcement_mode       = "Default"

  monthly_budget          = var.monthly_budget
  budget_start_date       = var.budget_start_date
  budget_alert_emails     = var.budget_alert_emails
  budget_action_group_ids = [module.observability.action_group_ticket_id]
}

module "aks" {
  source = "../../modules/aks-platform"
  count  = var.enable_aks ? 1 : 0

  name_prefix         = local.name_prefix
  environment         = local.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.compute.name

  subnet_id = module.network.platform_subnet_id

  # Standard tier for the uptime SLA. Free tier has none, which is acceptable
  # for a lab and not for a platform other teams depend on.
  sku_tier = "Standard"

  # 3 x Standard_D4ds_v5 = 24 vCPU at the ceiling. Run
  # ./scripts/bash/check-quota.sh prod before applying.
  node_vm_size   = "Standard_D4ds_v5"
  node_count_min = 2
  node_count_max = 6

  api_server_authorized_ip_ranges = var.operator_ip_ranges
  admin_group_object_ids = compact([
    lookup(module.identity.group_object_ids, "platform-admins", "")
  ])

  acr_id          = module.platform_services.registry_id
  enable_acr_pull = true

  log_analytics_workspace_id = module.observability.workspace_id
  # On in production: pod-level logs are worth the per-GB cost when an incident
  # postmortem depends on them.
  enable_container_insights = true

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

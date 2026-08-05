# =============================================================================
# Platform services — Key Vault and the container registry
# =============================================================================
# Both exist to support workloads that cannot use a managed identity end to
# end. That set is deliberately small: Azure targets are reached with workload
# identity, so what remains in the vault is credentials for things outside
# Azure — an SFTP source, a partner API key.
#
# The vault is RBAC-enabled rather than access-policy based. Access policies
# cannot be scoped below the whole vault, cannot be granted to a group without
# granting every secret in it, and do not appear in an Azure RBAC access review.
# =============================================================================

locals {
  # Key Vault names are globally unique, 3-24 characters, alphanumeric and
  # hyphens. Built deterministically so a destroy/apply cycle reclaims the same
  # name rather than needing a new one.
  vault_name = substr("kv-${var.name_prefix}-${var.environment}-${var.unique_suffix}", 0, 24)

  # Registry names allow no hyphens at all.
  registry_name = substr(lower(replace("acr${var.name_prefix}${var.environment}${var.unique_suffix}", "-", "")), 0, 50)

  tags = merge(var.tags, { component = "platform-services" })

  # Built as a local so the nested ip_rule iteration reads from the parent
  # iterator rather than reaching back out to var from inside two dynamic
  # blocks. Empty on Basic, where the API rejects a network rule set outright.
  registry_network_rules = var.registry_sku == "Premium" ? [{
    default_action = "Deny"
    ip_rules       = var.allowed_ip_ranges
  }] : []
}

resource "azurerm_key_vault" "this" {
  name                = local.vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # RBAC, not access policies. See the header.
  rbac_authorization_enabled = true

  # Soft delete is mandatory and cannot be turned off; the retention window is
  # the only choice. Seven days is the minimum and the right value for an
  # environment that is recreated often.
  soft_delete_retention_days = 7
  purge_protection_enabled   = var.enable_purge_protection

  # Disk encryption and template deployment do not need to read this vault, and
  # every enabled_for_* flag is a path that bypasses RBAC.
  enabled_for_disk_encryption     = false
  enabled_for_deployment          = false
  enabled_for_template_deployment = false

  public_network_access_enabled = true

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = var.allowed_subnet_ids
    ip_rules                   = var.allowed_ip_ranges
  }

  tags = local.tags
}

resource "azurerm_container_registry" "this" {
  count = var.enable_container_registry ? 1 : 0

  name                = local.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.registry_sku

  # The admin user is a shared username and password with push rights. Nothing
  # here needs it: CI pushes with a federated identity, the kubelet pulls with
  # AcrPull. Leaving it enabled creates a credential with no owner.
  admin_enabled = false

  # Network rules are a Premium feature. On Basic the registry is reachable
  # from the internet and the control that remains is authentication — which is
  # why admin_enabled above matters more here than it would on Premium.
  dynamic "network_rule_set" {
    for_each = local.registry_network_rules
    content {
      default_action = network_rule_set.value.default_action

      dynamic "ip_rule" {
        for_each = network_rule_set.value.ip_rules
        content {
          action   = "Allow"
          ip_range = ip_rule.value
        }
      }
    }
  }

  # Untagged manifests accumulate on every image rebuild and are billed as
  # storage forever. Retention is Premium-only, so on Basic this is null and
  # the pruning is handled by scripts/bash/prune-registry.sh instead — noted
  # here so the gap is visible rather than assumed covered.
  retention_policy_in_days = var.registry_sku == "Premium" ? 30 : null

  tags = local.tags
}

# ── Diagnostics ──────────────────────────────────────────────────────────────
# Key Vault audit events record every secret read. This is the log that answers
# "was this credential accessed before it was rotated", which is the first
# question asked in a suspected leak.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-${local.vault_name}"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "registry" {
  count = var.enable_container_registry && var.enable_diagnostics ? 1 : 0

  name                       = "diag-${local.registry_name}"
  target_resource_id         = azurerm_container_registry.this[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }
}

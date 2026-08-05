# =============================================================================
# Private endpoints — dfs and blob
# =============================================================================
# ADLS Gen2 needs both. The hierarchical-namespace API answers on the dfs
# endpoint, but AzCopy, the Databricks storage connector and anything using the
# older Blob REST surface still resolve <account>.blob.core.windows.net. An
# endpoint on dfs alone produces a lake that Databricks can query and AzCopy
# cannot reach, which is a confusing afternoon.
#
# Roughly EUR 7 per endpoint per month plus data processing, so ~EUR 14 for the
# pair. Off in sandbox, where the storage firewall plus service endpoints give
# the same network isolation without the standing charge — the difference being
# that service endpoints cannot satisfy public_network_access_enabled = false.
# =============================================================================

locals {
  private_endpoint_targets = var.enable_private_endpoints ? {
    dfs  = { subresource = "dfs", zone_key = "dfs" }
    blob = { subresource = "blob", zone_key = "blob" }
  } : {}
}

resource "azurerm_private_endpoint" "lake" {
  for_each = local.private_endpoint_targets

  name                = "pe-${local.account_name}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${local.account_name}-${each.key}"
    private_connection_resource_id = azurerm_storage_account.lake.id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  # Without this block the endpoint exists but nothing resolves to it, and
  # every client keeps reaching the public name. This is the step that is
  # skipped in most private-link rollouts.
  private_dns_zone_group {
    name                 = "pdz-${each.key}"
    private_dns_zone_ids = [var.private_dns_zone_ids[each.value.zone_key]]
  }
}

# ── Diagnostics ──────────────────────────────────────────────────────────────
# Storage diagnostics are the audit trail for data access. The read/write/delete
# log categories live on the blob sub-resource, not on the account, which is why
# this targets the nested resource ID.
resource "azurerm_monitor_diagnostic_setting" "lake_blob" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-${local.account_name}-blob"
  target_resource_id         = "${azurerm_storage_account.lake.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  # Capacity and transaction metrics feed the FinOps report and the
  # data-freshness dashboards.
  enabled_metric {
    category = "Transaction"
  }
}

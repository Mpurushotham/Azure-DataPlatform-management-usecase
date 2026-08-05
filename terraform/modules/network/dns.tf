# =============================================================================
# Private DNS — resolution for private endpoints
# =============================================================================
# A private endpoint without its DNS zone is the single most common way a
# private-link migration breaks: the endpoint exists, the NIC has an address,
# and every client keeps resolving the public name to a public address that
# firewall rules now reject. The zone is what makes the endpoint take effect.
#
# Zones are created here rather than in each consumer module so that one VNet
# link per zone is enough. At ~EUR 0.50 per zone per month plus query charges,
# the whole set costs about EUR 3/month — real, but an order of magnitude below
# the endpoints themselves.
# =============================================================================

locals {
  # Every zone this platform's private endpoints resolve into. ADLS Gen2 needs
  # both dfs and blob: the hierarchical namespace API answers on dfs, but the
  # Databricks and AzCopy paths still touch blob.
  private_dns_zones = var.enable_private_dns ? {
    dfs        = "privatelink.dfs.core.windows.net"
    blob       = "privatelink.blob.core.windows.net"
    keyvault   = "privatelink.vaultcore.azure.net"
    databricks = "privatelink.azuredatabricks.net"
    registry   = "privatelink.azurecr.io"
  } : {}
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# registration_enabled stays false: these zones hold manually-managed A records
# created by private endpoints, not auto-registered VM records. Enabling it on
# a shared zone lets any VM in the VNet claim a name in it.
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.private_dns_zones

  name                  = "link-${local.base_name}-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

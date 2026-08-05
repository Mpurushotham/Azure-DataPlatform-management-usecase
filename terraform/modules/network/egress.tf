# =============================================================================
# Egress — deterministic outbound for the injected subnets
# =============================================================================
# Azure retired default outbound access for VNets created after 30 September
# 2025. A VM in a subnet with no NAT gateway, no load balancer outbound rule and
# no public IP now has no internet path at all. That is the right default, but
# it means classic Databricks compute cannot reach its own control plane until
# an egress path exists.
#
# AKS is unaffected: its Standard Load Balancer carries outbound rules, and the
# platform subnet relies on that rather than duplicating a NAT gateway.
#
# The gateway is off in sandbox because that environment runs serverless
# Databricks compute, which egresses from Databricks' network rather than this
# VNet. See ADR-004.
# =============================================================================

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "pip-nat-${local.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"

  # Zone-redundant. A NAT gateway pinned to one zone takes every cluster in the
  # VNet offline when that zone fails, which converts a zonal incident into a
  # regional one.
  zones = ["1", "2", "3"]
  tags  = local.tags
}

resource "azurerm_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "nat-${local.base_name}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# A single NAT gateway across both Databricks subnets gives every cluster in
# the platform one predictable source address — which is what a partner
# allowlist or an on-premises firewall rule is written against.
resource "azurerm_subnet_nat_gateway_association" "databricks_host" {
  for_each = var.enable_nat_gateway ? local.databricks_subnets : {}

  subnet_id      = azurerm_subnet.databricks_host[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

resource "azurerm_subnet_nat_gateway_association" "databricks_container" {
  for_each = var.enable_nat_gateway ? local.databricks_subnets : {}

  subnet_id      = azurerm_subnet.databricks_container[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

# =============================================================================
# Network security groups
# =============================================================================
# Rules are separate `azurerm_network_security_rule` resources rather than
# inline `security_rule` blocks, on purpose. When a workspace is created,
# the Databricks resource provider adds its own worker-to-worker rules to the
# NSG attached to the injected subnets. With inline blocks Terraform treats
# those additions as drift and deletes them on the next apply, which breaks the
# workspace. As separate resources, the two sets coexist and Terraform only
# owns the rules it declared.
# =============================================================================

locals {
  # Documented Azure Databricks egress requirements for VNet-injected
  # workspaces. Each entry is a service tag rather than an address range so the
  # rules survive Azure re-IPing its own services.
  databricks_egress = {
    control_plane = { priority = 210, tag = "AzureDatabricks", port = "443" }
    metastore     = { priority = 220, tag = "Sql", port = "3306" }
    storage       = { priority = 230, tag = "Storage", port = "443" }
    eventhub      = { priority = 240, tag = "EventHub", port = "9093" }
    entra_id      = { priority = 250, tag = "AzureActiveDirectory", port = "443" }
  }
}

# ── Databricks NSG ───────────────────────────────────────────────────────────
# One NSG shared by every injected subnet. Per-workspace NSGs would allow
# per-domain egress policy, which is a real requirement at scale — but it is
# not one this platform has yet, and an NSG per workspace triples the rule
# surface to audit. Revisit when a domain needs an egress exception.
resource "azurerm_network_security_group" "databricks" {
  count = length(var.databricks_workspaces) > 0 ? 1 : 0

  name                = "nsg-dbx-${local.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { trust-level = "workload" })
}

resource "azurerm_network_security_rule" "databricks_inbound_vnet" {
  count = length(var.databricks_workspaces) > 0 ? 1 : 0

  name                        = "AllowWorkerToWorkerInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.databricks[0].name
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
}

# Secure Cluster Connectivity means the control plane never initiates a
# connection to a worker; the worker dials out and holds the tunnel open. So
# there is no inbound rule from the internet, and this deny is unconditional
# rather than gated on enable_strict_egress.
resource "azurerm_network_security_rule" "databricks_inbound_deny" {
  count = length(var.databricks_workspaces) > 0 ? 1 : 0

  name                        = "DenyAllInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.databricks[0].name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "databricks_outbound_vnet" {
  count = length(var.databricks_workspaces) > 0 ? 1 : 0

  name                        = "AllowWorkerToWorkerOutbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.databricks[0].name
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "databricks_outbound" {
  for_each = length(var.databricks_workspaces) > 0 ? local.databricks_egress : {}

  name                        = "AllowDatabricks${title(replace(each.key, "_", ""))}Outbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.databricks[0].name
  priority                    = each.value.priority
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = each.value.tag
}

resource "azurerm_network_security_rule" "databricks_outbound_deny" {
  count = length(var.databricks_workspaces) > 0 && var.enable_strict_egress ? 1 : 0

  name                        = "DenyAllOutbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.databricks[0].name
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "databricks_host" {
  for_each = local.databricks_subnets

  subnet_id                 = azurerm_subnet.databricks_host[each.key].id
  network_security_group_id = azurerm_network_security_group.databricks[0].id
}

resource "azurerm_subnet_network_security_group_association" "databricks_container" {
  for_each = local.databricks_subnets

  subnet_id                 = azurerm_subnet.databricks_container[each.key].id
  network_security_group_id = azurerm_network_security_group.databricks[0].id
}

# ── Platform NSG (AKS nodes) ─────────────────────────────────────────────────
resource "azurerm_network_security_group" "platform" {
  name                = "nsg-platform-${local.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { trust-level = "platform" })
}

# Operator access to the Airflow and Grafana UIs. Without an operator range
# this resource is not created at all, and the default deny below is the only
# inbound rule — which is the correct posture for an environment reached over
# a private endpoint or Bastion instead.
resource "azurerm_network_security_rule" "platform_operator_https" {
  count = length(var.operator_ip_ranges) > 0 ? 1 : 0

  name                        = "AllowOperatorHttpsInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.platform.name
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = var.operator_ip_ranges
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "platform_inbound_vnet" {
  name                        = "AllowVnetInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.platform.name
  priority                    = 300
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "platform_inbound_deny" {
  name                        = "DenyAllInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.platform.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "platform" {
  subnet_id                 = azurerm_subnet.platform.id
  network_security_group_id = azurerm_network_security_group.platform.id
}

# ── Private Link NSG ─────────────────────────────────────────────────────────
# Private endpoint NICs bypass NSG evaluation unless network policies are
# enabled on the subnet, which they are not (see main.tf). This NSG therefore
# governs anything else that ends up in the subnet by accident — which is
# exactly the point: a subnet with no NSG is a subnet nobody is watching.
resource "azurerm_network_security_group" "privatelink" {
  count = var.enable_private_endpoint_subnet ? 1 : 0

  name                = "nsg-pl-${local.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { trust-level = "restricted" })
}

resource "azurerm_network_security_rule" "privatelink_inbound_vnet" {
  count = var.enable_private_endpoint_subnet ? 1 : 0

  name                        = "AllowVnetInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.privatelink[0].name
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "privatelink_inbound_deny" {
  count = var.enable_private_endpoint_subnet ? 1 : 0

  name                        = "DenyAllInbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.privatelink[0].name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "privatelink" {
  count = var.enable_private_endpoint_subnet ? 1 : 0

  subnet_id                 = azurerm_subnet.privatelink[0].id
  network_security_group_id = azurerm_network_security_group.privatelink[0].id
}

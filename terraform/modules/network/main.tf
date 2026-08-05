# =============================================================================
# Network — segmentation by trust level, default deny between segments
# =============================================================================
# The address plan is fixed rather than computed from a pool, because a data
# platform's network is referenced from outside Terraform: firewall rules,
# on-premises route tables and partner allowlists all hard-code these ranges.
# A CIDR that moves when a list reorders is a CIDR that causes an incident.
#
#   <vnet>/16
#     .0.0/24    platform      AKS nodes — Airflow, Prometheus, Grafana
#     .1.0/24    privatelink   private endpoints for ADLS, Key Vault, Databricks
#     .2.0/26    firewall      AzureFirewallSubnet     (prod only)
#     .2.64/26   bastion       AzureBastionSubnet      (prod only)
#     .16.0/20   databricks    host/container pair per workspace, /24 each
#
# Trust levels, highest to lowest:
#
#   privatelink  no compute, only PaaS NICs. Nothing initiates from here.
#   databricks   runs customer code against customer data. Egress-controlled,
#                no inbound from anywhere but the Databricks control plane.
#   platform     runs orchestration. May call Databricks and ADLS, may not be
#                called by them.
#
# See docs/NETWORK-CIA.md for how each rule maps to Confidentiality, Integrity
# and Availability.
# =============================================================================

locals {
  base_name = "${var.name_prefix}-${var.environment}"

  # Databricks gets a contiguous /20 at offset .16.0 so the platform subnets
  # below it can grow without colliding.
  databricks_block = cidrsubnet(var.address_space, 4, 1)

  # Two subnets per workspace, allocated in pairs so workspace N always owns
  # indices 2N and 2N+1. Stable under list reordering only if the list is
  # append-only, which is why databricks_workspaces is documented as such.
  databricks_subnets = {
    for idx, ws in var.databricks_workspaces : ws => {
      host      = cidrsubnet(local.databricks_block, 4, idx * 2)
      container = cidrsubnet(local.databricks_block, 4, idx * 2 + 1)
    }
  }

  tags = merge(var.tags, {
    component = "network"
  })
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = local.tags
}

# ── Platform subnet (AKS nodes) ──────────────────────────────────────────────
resource "azurerm_subnet" "platform" {
  name                 = "snet-platform"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 0)]

  # Service endpoints, not private endpoints, for the storage path out of AKS.
  # A private endpoint per PaaS service is ~EUR 7/month; service endpoints are
  # free and keep the traffic on the Azure backbone. The difference that
  # matters — a private endpoint gives the service a VNet IP and so survives
  # public-network-access=Disabled — is why prod uses both and sandbox uses
  # only this.
  service_endpoints = [
    "Microsoft.Storage",
    "Microsoft.KeyVault",
    "Microsoft.ContainerRegistry",
  ]
}

# ── Private Link subnet ──────────────────────────────────────────────────────
resource "azurerm_subnet" "privatelink" {
  count = var.enable_private_endpoint_subnet ? 1 : 0

  name                 = "snet-privatelink"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 1)]

  # Private endpoint NICs must not have subnet network policies applied to
  # them, or the endpoint's own traffic is filtered by rules written for
  # workloads. NSG rules on this subnet still apply to everything else.
  private_endpoint_network_policies = "Disabled"
}

# ── Databricks injected subnets ──────────────────────────────────────────────
# Delegation hands subnet lifecycle operations to the Databricks resource
# provider. Without it, workspace creation fails: the provider cannot prepare
# the network policies it needs to place cluster NICs.
resource "azurerm_subnet" "databricks_host" {
  for_each = local.databricks_subnets

  name                 = "snet-dbx-${each.key}-host"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.host]

  service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]

  delegation {
    name = "databricks-host"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet" "databricks_container" {
  for_each = local.databricks_subnets

  name                 = "snet-dbx-${each.key}-container"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.container]

  service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]

  delegation {
    name = "databricks-container"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

output "vnet_id" {
  description = "Resource ID of the platform virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the platform virtual network."
  value       = azurerm_virtual_network.this.name
}

output "address_space" {
  description = "VNet CIDR, for peering and firewall rules written outside Terraform."
  value       = var.address_space
}

output "platform_subnet_id" {
  description = "Subnet ID for AKS nodes."
  value       = azurerm_subnet.platform.id
}

output "private_endpoint_subnet_id" {
  description = "Subnet ID for private endpoint NICs. Empty when the subnet is disabled."
  value       = var.enable_private_endpoint_subnet ? azurerm_subnet.privatelink[0].id : ""
}

output "databricks_subnet_ids" {
  description = "Per-workspace host and container subnet IDs, keyed by workspace name."
  value = {
    for ws in var.databricks_workspaces : ws => {
      host           = azurerm_subnet.databricks_host[ws].id
      container      = azurerm_subnet.databricks_container[ws].id
      host_name      = azurerm_subnet.databricks_host[ws].name
      container_name = azurerm_subnet.databricks_container[ws].name
    }
  }
}

output "databricks_nsg_id" {
  description = "NSG applied to the injected Databricks subnets. Empty when no workspaces are declared."
  value       = length(var.databricks_workspaces) > 0 ? azurerm_network_security_group.databricks[0].id : ""
}

output "databricks_nsg_association_ids" {
  description = <<-EOT
    NSG association resource IDs per workspace.

    Exported specifically so the Databricks workspace module can depend on
    them: Azure Databricks validates that both injected subnets already carry
    an NSG at creation time, and passing the association ID rather than the
    subnet ID is what makes Terraform order the association first.
  EOT
  value = {
    for ws in var.databricks_workspaces : ws => {
      host      = azurerm_subnet_network_security_group_association.databricks_host[ws].id
      container = azurerm_subnet_network_security_group_association.databricks_container[ws].id
    }
  }
}

output "private_dns_zone_ids" {
  description = "Private DNS zone resource IDs keyed by short name, consumed by the private endpoint blocks in other modules."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "nat_public_ip" {
  description = "Deterministic egress address for partner allowlists. Empty when the NAT gateway is disabled."
  value       = var.enable_nat_gateway ? azurerm_public_ip.nat[0].ip_address : ""
}

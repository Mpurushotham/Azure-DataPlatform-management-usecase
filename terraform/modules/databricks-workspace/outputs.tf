output "workspace_id" {
  description = "Azure resource ID of the Databricks workspace."
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_name" {
  description = "Databricks workspace name."
  value       = azurerm_databricks_workspace.this.name
}

output "workspace_url" {
  description = "Workspace hostname, used as the databricks provider host and by the Airflow connection."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "workspace_numeric_id" {
  description = "Numeric workspace ID that the account-level API uses to assign a metastore."
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "access_connector_id" {
  description = "Access Connector resource ID, referenced by the Unity Catalog storage credential."
  value       = azurerm_databricks_access_connector.this.id
}

output "access_connector_principal_id" {
  description = "Managed identity object ID of the Access Connector, granted Storage Blob Data Contributor on the lake."
  value       = azurerm_databricks_access_connector.this.identity[0].principal_id
}

output "managed_resource_group_name" {
  description = "Databricks-owned resource group, for cost attribution and for locating the DBFS root account."
  value       = azurerm_databricks_workspace.this.managed_resource_group_name
}

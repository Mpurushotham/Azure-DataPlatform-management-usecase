output "storage_account_id" {
  description = "Resource ID of the lake storage account."
  value       = azurerm_storage_account.lake.id
}

output "storage_account_name" {
  description = "Name of the lake storage account."
  value       = azurerm_storage_account.lake.name
}

output "dfs_endpoint" {
  description = "Primary DFS endpoint, the abfss:// host used by Databricks external locations."
  value       = azurerm_storage_account.lake.primary_dfs_endpoint
}

output "container_names" {
  description = "Container names created, keyed by medallion layer."
  value       = { for k, c in azurerm_storage_container.medallion : k => c.name }
}

output "container_urls" {
  description = "abfss:// URLs per container, consumed directly by the Unity Catalog external location definitions."
  value = {
    for k, c in azurerm_storage_container.medallion :
    k => "abfss://${c.name}@${azurerm_storage_account.lake.name}.dfs.core.windows.net/"
  }
}

output "identity_principal_id" {
  description = "System-assigned identity of the storage account, for CMK grants."
  value       = azurerm_storage_account.lake.identity[0].principal_id
}

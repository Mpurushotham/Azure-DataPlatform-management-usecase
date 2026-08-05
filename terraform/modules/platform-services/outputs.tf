output "key_vault_id" {
  description = "Key Vault resource ID, scope for the Key Vault Secrets User grants."
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Key Vault name, referenced by the CSI SecretProviderClass."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = azurerm_key_vault.this.vault_uri
}

output "registry_id" {
  description = "Container registry resource ID, scope for the kubelet AcrPull assignment. Empty when the registry is disabled."
  value       = var.enable_container_registry ? azurerm_container_registry.this[0].id : ""
}

output "registry_login_server" {
  description = "Registry hostname used in image references and by 'az acr login'."
  value       = var.enable_container_registry ? azurerm_container_registry.this[0].login_server : ""
}

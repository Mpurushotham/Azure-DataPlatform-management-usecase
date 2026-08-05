output "policy_set_definition_id" {
  description = "Resource ID of the platform baseline initiative."
  value       = azurerm_policy_set_definition.baseline.id
}

output "policy_assignment_id" {
  description = "Resource ID of the subscription-scoped baseline assignment, used when querying compliance state."
  value       = azurerm_subscription_policy_assignment.baseline.id
}

output "policy_definition_ids" {
  description = "Individual policy definition IDs keyed by short name, for exemptions scoped to a single control."
  value = {
    require-tags            = azurerm_policy_definition.require_tags.id
    allowed-locations       = azurerm_policy_definition.allowed_locations.id
    deny-storage-public     = azurerm_policy_definition.deny_storage_public.id
    storage-secure-transfer = azurerm_policy_definition.storage_secure_transfer.id
    databricks-secure       = azurerm_policy_definition.databricks_secure.id
  }
}

output "budget_id" {
  description = "Resource ID of the subscription budget."
  value       = azurerm_consumption_budget_subscription.platform.id
}

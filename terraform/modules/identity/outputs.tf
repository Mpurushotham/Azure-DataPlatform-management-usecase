output "group_object_ids" {
  description = "Entra group object IDs keyed by logical name, consumed by the Unity Catalog grant definitions."
  value       = local.group_object_ids
}

output "group_display_names" {
  description = "Entra group display names, used as Unity Catalog principal names once SCIM has synchronised them."
  value       = { for k, _ in local.all_groups : k => "${var.name_prefix}-${k}" }
}

output "airflow_identity_client_id" {
  description = "Client ID for the Airflow workload identity, referenced by the Kubernetes ServiceAccount annotation."
  value       = azurerm_user_assigned_identity.airflow.client_id
}

output "airflow_identity_principal_id" {
  description = "Object ID of the Airflow workload identity, for grants made outside this module."
  value       = azurerm_user_assigned_identity.airflow.principal_id
}

output "airflow_identity_id" {
  description = "Resource ID of the Airflow workload identity, for the federated credential in the AKS module."
  value       = azurerm_user_assigned_identity.airflow.id
}

output "airflow_identity_name" {
  description = "Name of the Airflow workload identity."
  value       = azurerm_user_assigned_identity.airflow.name
}

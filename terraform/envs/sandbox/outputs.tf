# Outputs consumed by three things: the Makefile, the sandbox-databricks root
# through a remote state data source, and the Helm values that configure
# Airflow. Anything a human needs to copy by hand belongs here.

output "resource_groups" {
  description = "Resource group names by purpose."
  value = {
    network       = azurerm_resource_group.network.name
    data          = azurerm_resource_group.data.name
    databricks    = azurerm_resource_group.databricks.name
    compute       = azurerm_resource_group.compute.name
    observability = azurerm_resource_group.observability.name
    security      = azurerm_resource_group.security.name
  }
}

output "lake_container_urls" {
  description = "abfss:// URLs per medallion layer, registered as Unity Catalog external locations by the databricks root."
  value       = module.data_lake.container_urls
}

output "storage_account_id" {
  description = "Data lake storage account ID."
  value       = module.data_lake.storage_account_id
}

output "storage_account_name" {
  description = "Data lake storage account name."
  value       = module.data_lake.storage_account_name
}

output "databricks_workspaces" {
  description = "Per-workspace URL, Access Connector and managed resource group, keyed by workspace."
  value = {
    for k, w in module.databricks : k => {
      url                           = w.workspace_url
      workspace_id                  = w.workspace_id
      access_connector_id           = w.access_connector_id
      access_connector_principal_id = w.access_connector_principal_id
      managed_resource_group        = w.managed_resource_group_name
    }
  }
}

output "entra_group_names" {
  description = "Entra group display names, used as Unity Catalog grant principals once SCIM has synchronised them."
  value       = module.identity.group_display_names
}

output "entra_group_object_ids" {
  description = "Entra group object IDs."
  value       = module.identity.group_object_ids
}

output "airflow_identity_client_id" {
  description = "Client ID annotated on the Airflow ServiceAccount for workload identity."
  value       = module.identity.airflow_identity_client_id
}

output "aks_cluster_name" {
  description = "AKS cluster name. Consumed by 'make kubeconfig', 'make stop' and 'make start'."
  value       = var.enable_aks ? module.aks[0].cluster_name : ""
}

output "aks_resource_group" {
  description = "Resource group holding the AKS cluster."
  value       = azurerm_resource_group.compute.name
}

output "acr_login_server" {
  description = "Container registry hostname for the custom Airflow image."
  value       = module.platform_services.registry_login_server
}

output "key_vault_name" {
  description = "Key Vault name, referenced by the CSI SecretProviderClass."
  value       = module.platform_services.key_vault_name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = module.observability.workspace_id
}

output "next_steps" {
  description = "What to run after this root applies."
  value       = <<-EOT
    1. Confirm a Unity Catalog metastore exists in ${var.location}:
         ./scripts/bash/check-metastore.sh

    2. Apply the Databricks governance root (Unity Catalog, cluster policies,
       SQL warehouse). It reads this root's outputs from remote state:
         make plan  ENV=sandbox-databricks
         make apply ENV=sandbox-databricks

    3. Build and push the Airflow image, then install the in-cluster platform:
         make kubeconfig ENV=sandbox
         make platform-deploy ENV=sandbox

    Cost control — this environment bills by the hour:
         make stop ENV=sandbox      park the cluster, keep the state
         make cost ENV=sandbox      month-to-date by tag
         make destroy ENV=sandbox   remove everything
  EOT
}

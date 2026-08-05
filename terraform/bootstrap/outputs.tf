output "terraform_identity_client_id" {
  description = "Client ID CI presents when federating. Set as AZURE_CLIENT_ID in GitHub Actions."
  value       = azurerm_user_assigned_identity.terraform.client_id
}

output "terraform_identity_principal_id" {
  description = "Object ID of the CI identity, for any RBAC assigned outside this root."
  value       = azurerm_user_assigned_identity.terraform.principal_id
}

output "state_storage_account_name" {
  description = "Storage account holding remote state."
  value       = data.azurerm_storage_account.state.name
}

output "backend_config_hcl" {
  description = "Ready-to-write backend.hcl content per environment. Consumed by 'make backend-config'."
  value = {
    for env in var.environments : env => join("\n", [
      "resource_group_name  = \"${data.azurerm_resource_group.state.name}\"",
      "storage_account_name = \"${data.azurerm_storage_account.state.name}\"",
      "container_name       = \"${azurerm_storage_container.state[env].name}\"",
      "key                  = \"${env}.terraform.tfstate\"",
      "use_azuread_auth     = true",
    ])
  }
}

output "github_secrets" {
  description = "Values to set as GitHub Actions repository secrets/variables. None of them are sensitive — that is the point of federation."
  value = {
    AZURE_CLIENT_ID       = azurerm_user_assigned_identity.terraform.client_id
    AZURE_TENANT_ID       = var.tenant_id
    AZURE_SUBSCRIPTION_ID = var.subscription_id
  }
}

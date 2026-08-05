variable "subscription_id" {
  description = "Azure subscription that hosts the platform and its Terraform state."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant backing the subscription."
  type        = string
}

variable "state_resource_group_name" {
  description = <<-EOT
    Resource group that already holds the Terraform state storage account.
    This root adopts an existing account by data source rather than creating a
    new one: a second storage account for state would double the blast radius
    of a state-store outage for no benefit.
  EOT
  type        = string
  default     = "rg-rebtel-lab-cicd"
}

variable "state_storage_account_name" {
  description = "Existing storage account used for remote Terraform state."
  type        = string
  default     = "strebtellabtfstate6b1f"
}

variable "environments" {
  description = "Environments that get an isolated state container. One container per environment keeps a sandbox mistake from touching prod state."
  type        = list(string)
  default     = ["sandbox", "prod"]
}

variable "location" {
  description = "Azure region for the CI identity."
  type        = string
  default     = "swedencentral"
}

variable "name_prefix" {
  description = "Platform short name, used in every resource name and in cost attribution."
  type        = string
  default     = "yoda"
}

variable "github_repository" {
  description = "GitHub repo in owner/name form, used as the OIDC federated credential subject."
  type        = string
  default     = "Mpurushotham/Azure-DataPlatform-management-usecase"
}

variable "github_environments" {
  description = "GitHub Environments that may assume the Terraform identity. Deployment to prod is gated on the GitHub environment's own approval rules."
  type        = list(string)
  default     = ["sandbox", "prod"]
}

variable "azure_devops_organization" {
  description = "Azure DevOps organisation name. Leave empty to skip the ADO federated credential."
  type        = string
  default     = ""
}

variable "azure_devops_project" {
  description = "Azure DevOps project name for the service connection subject."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to bootstrap resources."
  type        = map(string)
  default = {
    platform   = "yoda"
    component  = "cicd"
    managed-by = "terraform"
  }
}

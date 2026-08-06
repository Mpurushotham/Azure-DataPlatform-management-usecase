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

variable "github_subject_prefix" {
  description = <<-EOT
    Prefix of the OIDC `sub` claim GitHub actually presents, without the
    trailing `:environment:<name>` or `:pull_request`.

    Leave empty to use the documented form, `repo:<owner>/<repo>`. That is what
    every guide shows, and for a growing number of repositories it is no longer
    what GitHub sends: the subject is issued with immutable numeric owner and
    repository IDs appended, e.g.

      repo:acme@23453932/my-repo@1324202164

    The IDs make the credential survive a rename, which is an improvement — but
    a federated credential built from the documented form then fails to match,
    with an error that names the subject and not the reason:

      AADSTS700213: No matching federated identity record found for presented
      assertion subject '...'

    Read the value GitHub will actually use rather than assuming either form:

      gh api repos/<owner>/<repo>/actions/oidc/customization/sub \
        --jq .sub_claim_prefix
  EOT
  type        = string
  default     = ""
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

variable "subscription_id" {
  description = "Azure subscription hosting the platform."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant backing the subscription."
  type        = string
}

variable "state_resource_group_name" {
  description = "Resource group holding the Terraform state account, for the remote state data source."
  type        = string
  default     = "rg-rebtel-lab-cicd"
}

variable "state_storage_account_name" {
  description = "Storage account holding remote state."
  type        = string
  default     = "strebtellabtfstate6b1f"
}

variable "state_container_name" {
  description = "Container holding the sandbox root's state."
  type        = string
  default     = "tfstate-yoda-sandbox"
}

variable "state_key" {
  description = "Blob name of the sandbox root's state."
  type        = string
  default     = "sandbox.terraform.tfstate"
}

variable "enable_grants" {
  description = <<-EOT
    Apply Unity Catalog grants to the Entra groups.

    Off until SCIM provisioning has synchronised those groups into the
    Databricks account. A grant naming a principal Databricks has never seen
    fails the apply with a message that does not mention SCIM at all.
    See docs/RUNBOOKS.md#scim-provisioning.
  EOT
  type        = bool
  default     = false
}

variable "enable_sql_warehouse" {
  description = "Create the serverless SQL warehouse per workspace. Costs nothing while stopped."
  type        = bool
  default     = true
}

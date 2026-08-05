terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Remote state, because CI cannot operate local state and because the
  # databricks root reads this root's outputs through a remote state data
  # source. The container is created by terraform/bootstrap.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # The lake and the state account both set shared_access_key_enabled = false,
  # so the provider's own data-plane calls must authenticate with Entra too.
  # Without this the apply fails with KeyBasedAuthenticationNotPermitted while
  # polling the blob service.
  storage_use_azuread = true

  features {
    key_vault {
      # A sandbox is recreated often and a soft-deleted vault holds its name.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # `make destroy ENV=sandbox` must actually work.
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

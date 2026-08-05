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

  # Bootstrap deliberately keeps local state. The thing that creates the state
  # backend cannot itself live in that backend, and the chicken-and-egg dance of
  # `init -migrate-state` afterwards buys nothing: this root is applied once,
  # its outputs are stable, and losing its state costs a re-import of four
  # resources rather than an outage.
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # The state storage account sets shared_access_key_enabled = false, so the
  # provider's own data-plane calls must authenticate with Entra as well.
  # Without this, container creation fails with KeyBasedAuthenticationNotPermitted.
  storage_use_azuread = true

  features {}
}

provider "azuread" {
  tenant_id = var.tenant_id
}

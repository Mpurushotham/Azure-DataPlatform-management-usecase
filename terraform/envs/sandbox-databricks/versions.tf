# =============================================================================
# Environment: sandbox-databricks — Unity Catalog and compute policy
# =============================================================================
# A second root, and the reason is a hard Terraform constraint rather than a
# preference: the databricks provider needs a `host`, and that host is the
# workspace URL, which does not exist until the workspace is created. A
# provider configuration cannot depend on a resource created in the same apply
# — Terraform must configure every provider before it builds the graph.
#
# The alternatives and why they lose:
#
#   single root, two-phase apply with -target   works, but -target is a
#     documented escape hatch that skips dependency checking, and it has to be
#     remembered on every clean apply and every CI run
#   provider host from a variable              means applying once, reading a
#     URL out, pasting it into tfvars, applying again — the same two phases
#     with a manual step in the middle and no record of which URL was used
#
# Two roots make the dependency explicit and machine-readable: this one reads
# the other's outputs through a remote state data source, so CI can run them
# in order without anyone remembering anything. See ADR-008.
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.100"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  storage_use_azuread = true
  features {}
}

# One provider alias per workspace. Terraform cannot select a provider
# dynamically from a for_each key, so each workspace gets an explicit block —
# which is also the only form that makes the workspace-to-catalog mapping
# readable at a glance.
#
# No credentials appear here. The provider falls back to the Azure CLI login,
# and in CI to the federated workload identity, so there is no Databricks PAT
# anywhere in this repo.
provider "databricks" {
  alias = "central"
  host  = data.terraform_remote_state.sandbox.outputs.databricks_workspaces["central"].url
}

provider "databricks" {
  alias = "logistics"
  host  = data.terraform_remote_state.sandbox.outputs.databricks_workspaces["logistics"].url
}

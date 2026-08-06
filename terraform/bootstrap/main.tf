# =============================================================================
# Bootstrap — remote state containers and the CI identity
# =============================================================================
# Run once per subscription, before any environment root. It creates the two
# things that every later apply depends on and that Terraform therefore cannot
# create for itself:
#
#   1. A state container per environment.
#   2. A user-assigned managed identity that CI federates into, so neither
#      GitHub Actions nor Azure DevOps ever stores an Azure credential.
#
# The storage account itself is adopted, not created — see the data source
# below and the note in variables.tf.
# =============================================================================

data "azurerm_subscription" "current" {}

locals {
  # GitHub may issue either the documented subject prefix or an immutable,
  # ID-qualified one. Whichever it is, the federated credential must match it
  # exactly — see the note on var.github_subject_prefix.
  github_subject_prefix = (
    var.github_subject_prefix != ""
    ? var.github_subject_prefix
    : "repo:${var.github_repository}"
  )
}

data "azurerm_resource_group" "state" {
  name = var.state_resource_group_name
}

data "azurerm_storage_account" "state" {
  name                = var.state_storage_account_name
  resource_group_name = data.azurerm_resource_group.state.name
}

# One container per environment. Terraform's azurerm backend locks per state
# blob, so separate containers are not strictly required for concurrency — they
# exist so that a data-plane RBAC assignment can be scoped to a single
# environment later without splitting the account.
resource "azurerm_storage_container" "state" {
  for_each = toset(var.environments)

  name                  = "tfstate-${var.name_prefix}-${each.value}"
  storage_account_id    = data.azurerm_storage_account.state.id
  container_access_type = "private"
}

# ── CI identity ──────────────────────────────────────────────────────────────
# A user-assigned identity rather than an app registration with a secret. The
# federated credentials below mean there is no secret to rotate, leak or expire,
# which is the whole point: the most common way a platform gets compromised is a
# long-lived CI credential in a variable group.
resource "azurerm_user_assigned_identity" "terraform" {
  name                = "id-${var.name_prefix}-terraform"
  resource_group_name = data.azurerm_resource_group.state.name
  location            = var.location
  tags                = var.tags
}

# GitHub Actions — one credential per environment. The subject is pinned to the
# environment, not to a branch: a pull request from a fork cannot select a
# GitHub Environment, so this is what stops a fork PR from planning against
# prod.
resource "azurerm_federated_identity_credential" "github_environment" {
  for_each = toset(var.github_environments)

  name                = "fic-github-${each.value}"
  resource_group_name = data.azurerm_resource_group.state.name
  parent_id           = azurerm_user_assigned_identity.terraform.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "${local.github_subject_prefix}:environment:${each.value}"
}

# Pull requests plan but never apply, so they get a subject of their own and the
# read-only role assignment further down.
resource "azurerm_federated_identity_credential" "github_pull_request" {
  name                = "fic-github-pr"
  resource_group_name = data.azurerm_resource_group.state.name
  parent_id           = azurerm_user_assigned_identity.terraform.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "${local.github_subject_prefix}:pull_request"
}

# Azure DevOps — optional, because the pipeline is written to skip its
# Azure-dependent stages cleanly when no service connection is configured.
resource "azurerm_federated_identity_credential" "azure_devops" {
  count = var.azure_devops_organization != "" ? 1 : 0

  name                = "fic-ado-${var.name_prefix}"
  resource_group_name = data.azurerm_resource_group.state.name
  parent_id           = azurerm_user_assigned_identity.terraform.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://vstoken.dev.azure.com/${var.azure_devops_organization}"
  subject             = "sc://${var.azure_devops_organization}/${var.azure_devops_project}/sc-${var.name_prefix}-terraform"
}

# ── Permissions ──────────────────────────────────────────────────────────────
# Owner, not Contributor. The platform assigns RBAC roles of its own — Storage
# Blob Data Contributor to the Databricks Access Connector, AcrPull to the
# kubelet identity — and Contributor cannot create role assignments. The
# narrower alternative is Contributor plus Role Based Access Control
# Administrator; that is what a shared subscription should use, and it is left
# as a variable-free comment here because this subscription is single-tenant.
resource "azurerm_role_assignment" "terraform_subscription" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Owner"
  principal_id         = azurerm_user_assigned_identity.terraform.principal_id
}

# Data-plane access to state. The account has shared keys disabled, so this
# assignment — not a connection string — is what lets CI read and write state.
resource "azurerm_role_assignment" "terraform_state_blob" {
  scope                = data.azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform.principal_id
}

# =============================================================================
# Identity — groups as the only grantable principal, federation over secrets
# =============================================================================
# Two rules the whole platform is built on:
#
#   1. Nothing is granted to a user. Every Unity Catalog grant and every Azure
#      role assignment targets a group. A joiner/mover/leaver process that has
#      to hunt for direct grants is a process that misses some, and the misses
#      are invisible until an audit finds them.
#
#   2. Nothing holds a secret. Workloads use managed identities and workload
#      identity federation; CI uses OIDC federation. There is no client secret
#      in this platform to rotate, expire or leak. See ADR-005.
# =============================================================================

locals {
  base_name = "${var.name_prefix}-${var.environment}"

  # Platform-wide roles. Domain roles are generated per domain below.
  platform_groups = {
    platform-admins = {
      description = "Owns the platform: Terraform, cluster policies, metastore configuration."
    }
    data-engineers = {
      description = "Builds and operates pipelines. Write access to bronze and silver across domains."
    }
    data-analysts = {
      description = "Consumes gold. Read-only, and only through Unity Catalog."
    }
  }

  # Reader and writer per domain. Two levels rather than four: a third level
  # invariably ends up meaning 'writer, but we were nervous', which is not an
  # access decision anyone can review.
  domain_groups = merge([
    for d in var.domains : {
      "domain-${d}-readers" = {
        description = "Read access to the ${d} domain catalog."
      }
      "domain-${d}-writers" = {
        description = "Write access to the ${d} domain catalog."
      }
    }
  ]...)

  all_groups = merge(local.platform_groups, local.domain_groups)

  # Resolve to object IDs regardless of whether this module created the groups
  # or is consuming pre-existing ones.
  group_object_ids = var.manage_entra_groups ? {
    for k, g in azuread_group.this : k => g.object_id
  } : var.existing_group_ids

  tags = merge(var.tags, { component = "identity" })
}

resource "azuread_group" "this" {
  for_each = var.manage_entra_groups ? local.all_groups : {}

  display_name     = "${var.name_prefix}-${each.key}"
  description      = each.value.description
  security_enabled = true

  # Assignable to directory roles is deliberately false. These are data-access
  # groups; letting one also carry a directory role means a Unity Catalog grant
  # and a tenant-wide privilege share a membership list.
  assignable_to_role = false

  owners = length(var.platform_admin_object_ids) > 0 ? var.platform_admin_object_ids : null

  lifecycle {
    # Membership is managed by the joiner/mover/leaver process or by SCIM, not
    # by Terraform. Terraform owns that the group exists and what it may reach;
    # who is in it changes far more often than this repo does.
    ignore_changes = [members]
  }
}

# ── Workload identities ──────────────────────────────────────────────────────
# One identity per workload, never a shared one. A shared identity means a
# compromise of the smallest workload grants everything the largest one can do,
# and it makes the access logs unattributable.
resource "azurerm_user_assigned_identity" "airflow" {
  name                = "id-${local.base_name}-airflow"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(local.tags, { workload = "airflow" })
}

# ── Data-plane grants ────────────────────────────────────────────────────────
# Airflow orchestrates; it does not process data. It needs to read the landing
# zone to check arrival and write checkpoints, and that is all. Bronze, silver
# and gold are reached through Unity Catalog by the Databricks job, using the
# job's own identity, not Airflow's.
resource "azurerm_role_assignment" "airflow_lake_reader" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.airflow.principal_id

  description = "Arrival checks against the landing container. Write access is deliberately withheld — Airflow triggers work, it does not do it."
}

resource "azurerm_role_assignment" "airflow_key_vault" {
  count = var.enable_key_vault_grant ? 1 : 0

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.airflow.principal_id

  description = "Reads connection material for non-Azure sources. Azure targets use the managed identity directly and need no secret."
}

# Platform admins get data-plane access to the lake for break-glass inspection.
# Scoped to the group, time-bound in prod through PIM — see docs/SECURITY.md,
# which explains why PIM is documented rather than coded here.
resource "azurerm_role_assignment" "admins_lake" {
  count = contains(keys(local.group_object_ids), "platform-admins") ? 1 : 0

  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.group_object_ids["platform-admins"]

  description = "Break-glass access to the lake for platform administrators."
}

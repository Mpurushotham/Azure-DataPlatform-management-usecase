# =============================================================================
# Governance — policy as code, and a budget that tells the truth
# =============================================================================
# Guardrails, not gates. Each policy below blocks a specific way this platform
# could leak data or lose cost attribution, and each one is written so that the
# error message tells the person who hit it what to do instead.
#
# Deliberately absent: any policy that enforces naming. Names are enforced by
# the modules, which is a compile-time check rather than a deploy-time one, and
# a naming policy only ever fires on things Terraform did not create.
# =============================================================================

locals {
  policy_name = "${var.name_prefix}-${var.environment}"
}

# ── Mandatory tags ───────────────────────────────────────────────────────────
# The tag list is baked into the rule at plan time rather than passed as a
# policy parameter. Azure Policy cannot iterate an array parameter inside an
# anyOf, so the alternative is one policy definition per tag — four objects to
# review instead of one, all saying the same thing.
resource "azurerm_policy_definition" "require_tags" {
  name         = "${local.policy_name}-require-tags"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require platform tags (${join(", ", var.mandatory_tags)})"

  description = <<-EOT
    Every resource must carry the tags the FinOps report and the incident
    process read. Missing tags mean spend that cannot be attributed to a domain
    and a resource whose owner has to be found by asking around.
  EOT

  metadata = jsonencode({
    category = "Tags"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
      metadata      = { displayName = "Effect" }
    }
  })

  # Indexed mode already excludes resource groups and subscriptions, so this
  # only ever evaluates taggable resources.
  policy_rule = jsonencode({
    if = {
      anyOf = [
        for tag in var.mandatory_tags : {
          field  = "tags['${tag}']"
          exists = "false"
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

# ── Allowed locations ────────────────────────────────────────────────────────
# Data residency is the reason, not cost. A Swedish logistics platform placing
# data outside the EU is a compliance incident regardless of what it costs.
resource "azurerm_policy_definition" "allowed_locations" {
  name         = "${local.policy_name}-allowed-locations"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Allowed locations"

  description = "Restricts resource placement to the regions this platform is certified to operate in. Data residency control, not a cost control."

  metadata = jsonencode({
    category = "General"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    listOfAllowedLocations = {
      type         = "Array"
      metadata     = { displayName = "Allowed locations", strongType = "location" }
      defaultValue = ["swedencentral"]
    }
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field = "location"
          notIn = "[parameters('listOfAllowedLocations')]"
        },
        # 'global' is where Azure places things that have no region — private
        # DNS zones, for one. Without this exclusion the policy blocks the DNS
        # that private endpoints depend on.
        {
          field     = "location"
          notEquals = "global"
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

# ── Storage: no public network access ────────────────────────────────────────
resource "azurerm_policy_definition" "deny_storage_public" {
  name         = "${local.policy_name}-deny-storage-public"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Deny storage accounts with public blob access"

  description = "Blocks anonymous container access. This is the setting behind most public data-lake exposures; there is no legitimate use for it here."

  metadata = jsonencode({
    category = "Storage"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        {
          field     = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess"
          notEquals = "false"
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

# ── Storage: TLS floor and shared-key ban ────────────────────────────────────
# Two conditions in one definition because they describe the same intent — the
# account must only be reachable by an authenticated, encrypted caller — and
# splitting them produces two compliance rows that are always violated together.
resource "azurerm_policy_definition" "storage_secure_transfer" {
  name         = "${local.policy_name}-storage-secure-transfer"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require TLS 1.2 and Entra-only auth on storage"

  description = <<-EOT
    Storage accounts must set minimumTlsVersion TLS1_2 and disable shared key
    authorisation. Shared keys are the credential that ends up pasted into a
    notebook; disabling them forces every caller through Entra, where access
    can be reviewed and revoked.
  EOT

  metadata = jsonencode({
    category = "Storage"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        {
          anyOf = [
            {
              field     = "Microsoft.Storage/storageAccounts/minimumTlsVersion"
              notEquals = "TLS1_2"
            },
            {
              field     = "Microsoft.Storage/storageAccounts/allowSharedKeyAccess"
              notEquals = "false"
            }
          ]
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

# ── Databricks: no public IP, premium only ───────────────────────────────────
# Secure Cluster Connectivity is what keeps cluster nodes off the public
# internet. A workspace created without it cannot be converted in place — it has
# to be recreated — so this is a deny at creation or it is nothing.
resource "azurerm_policy_definition" "databricks_secure" {
  name         = "${local.policy_name}-databricks-secure"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require Databricks Secure Cluster Connectivity and Premium tier"

  description = <<-EOT
    Databricks workspaces must set enableNoPublicIp and use the Premium SKU.
    No public IP keeps cluster nodes off the internet; Premium is what makes
    Unity Catalog, cluster policies and audit logging available at all. Neither
    can be turned on after creation.
  EOT

  metadata = jsonencode({
    category = "Databricks"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
      metadata      = { displayName = "Effect" }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Databricks/workspaces" },
        {
          anyOf = [
            {
              field     = "Microsoft.Databricks/workspaces/parameters.enableNoPublicIp.value"
              notEquals = "true"
            },
            {
              field = "Microsoft.Databricks/workspaces/sku.name"
              notIn = ["premium"]
            }
          ]
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })
}

# ── Initiative ───────────────────────────────────────────────────────────────
# One assignment to manage, one compliance view to read. Individually assigned
# policies drift apart in scope and exemptions until nobody can say what the
# baseline is.
resource "azurerm_policy_set_definition" "baseline" {
  name         = "${local.policy_name}-baseline"
  policy_type  = "Custom"
  display_name = "${upper(var.name_prefix)} platform baseline (${var.environment})"

  description = "Security, residency and cost-attribution guardrails for the data platform. See docs/SECURITY.md for the control mapping."

  metadata = jsonencode({
    category = "Platform baseline"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    tagEffect = {
      type         = "String"
      defaultValue = "Audit"
      metadata     = { displayName = "Effect for the mandatory tag policy" }
    }
    securityEffect = {
      type         = "String"
      defaultValue = "Deny"
      metadata     = { displayName = "Effect for the security policies" }
    }
    allowedLocations = {
      type         = "Array"
      defaultValue = ["swedencentral"]
      metadata     = { displayName = "Allowed locations", strongType = "location" }
    }
  })

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.require_tags.id
    reference_id         = "RequireTags"
    parameter_values = jsonencode({
      effect = { value = "[parameters('tagEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.allowed_locations.id
    reference_id         = "AllowedLocations"
    parameter_values = jsonencode({
      effect                 = { value = "[parameters('securityEffect')]" }
      listOfAllowedLocations = { value = "[parameters('allowedLocations')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.deny_storage_public.id
    reference_id         = "DenyStoragePublic"
    parameter_values = jsonencode({
      effect = { value = "[parameters('securityEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.storage_secure_transfer.id
    reference_id         = "StorageSecureTransfer"
    parameter_values = jsonencode({
      effect = { value = "[parameters('securityEffect')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.databricks_secure.id
    reference_id         = "DatabricksSecure"
    parameter_values = jsonencode({
      effect = { value = "[parameters('securityEffect')]" }
    })
  }
}

resource "azurerm_subscription_policy_assignment" "baseline" {
  name                 = "${local.policy_name}-baseline"
  display_name         = "${upper(var.name_prefix)} platform baseline (${var.environment})"
  policy_definition_id = azurerm_policy_set_definition.baseline.id
  subscription_id      = "/subscriptions/${var.subscription_id}"
  enforce              = var.enforcement_mode == "Default"

  description = "Applied by terraform/modules/governance. Exemptions belong in version control, not in the portal."

  parameters = jsonencode({
    tagEffect        = { value = var.tag_policy_effect }
    securityEffect   = { value = var.security_policy_effect }
    allowedLocations = { value = var.allowed_locations }
  })

  non_compliance_message {
    content = "Blocked by the ${upper(var.name_prefix)} platform baseline. Required tags: ${join(", ", var.mandatory_tags)}. Storage must use TLS 1.2 with shared keys disabled. Databricks must be Premium with no public IP. See docs/SECURITY.md."
  }
}

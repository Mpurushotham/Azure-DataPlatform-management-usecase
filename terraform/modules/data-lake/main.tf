# =============================================================================
# Data lake — ADLS Gen2, medallion layout, Entra-only access
# =============================================================================
# One storage account, containers as the isolation boundary. The alternative —
# an account per medallion layer — buys independent firewall rules and quota,
# and costs a Unity Catalog external location per account plus a private
# endpoint pair per account. At this size the container boundary is enough,
# because the access decision is made by Unity Catalog grants rather than by
# storage RBAC: no human and no job holds a data-plane role on this account.
#
# The controls that matter, and what each one is actually defending against:
#
#   is_hns_enabled              directory semantics; without it, Delta's
#                               rename-based commit protocol is not atomic and
#                               concurrent writers corrupt the table
#   shared_access_key_enabled   false — removes the credential that gets pasted
#                               into a notebook and never rotated
#   min_tls_version             TLS1_2 — the compliance floor
#   infrastructure_encryption   a second encryption pass at the platform layer
#   default_action = Deny       the account is unreachable except from declared
#                               subnets, even with a valid Entra token
# =============================================================================

locals {
  # Storage account names: lowercase alphanumeric, 3-24 characters, globally
  # unique. Built rather than randomised so that a destroy/apply cycle returns
  # the same name and external references keep resolving.
  account_name = substr(
    lower(replace("st${var.name_prefix}${var.environment}${var.unique_suffix}", "-", "")),
    0, 24
  )

  # The storage firewall rejects /32 outright: it accepts a bare address or a
  # prefix between /0 and /30. Every other Azure firewall in this repo accepts
  # /32 happily, so the operator IP list is written once in CIDR form and
  # normalised here rather than being special-cased by every caller.
  storage_ip_rules = [
    for cidr in var.allowed_ip_ranges :
    endswith(cidr, "/32") ? trimsuffix(cidr, "/32") : cidr
  ]

  # Medallion, plus the containers the platform itself needs. Each carries the
  # classification that drives the Purview scan scope and the retention rule
  # below.
  containers = {
    landing = {
      classification = "raw-untrusted"
      description    = "Source-aligned drop zone. Nothing reads from here except the bronze ingest job."
    }
    bronze = {
      classification = "internal"
      description    = "Raw history, append-only, schema-on-read."
    }
    silver = {
      classification = "internal"
      description    = "Cleansed, conformed, deduplicated."
    }
    gold = {
      classification = "internal"
      description    = "Business-level aggregates serving reporting and data products."
    }
    quarantine = {
      classification = "restricted"
      description    = "Records that failed data-quality gates, held for inspection."
    }
    checkpoints = {
      classification = "internal"
      description    = "Structured Streaming checkpoints. Never tiered — a cold checkpoint stalls a stream."
    }
    metastore = {
      classification = "internal"
      description    = "Unity Catalog managed-table root. Written only by the Access Connector identity."
    }
    exports = {
      classification = "restricted"
      description    = "Outbound data products — partner extracts and Delta Sharing staging. Restricted because anything here is, by definition, about to leave."
    }
  }
}

resource "azurerm_storage_account" "lake" {
  name                     = local.account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  account_kind             = "StorageV2"

  # The whole point: a hierarchical namespace. Blob-flat storage cannot give
  # Delta an atomic rename, and directory-level ACLs do not exist without it.
  is_hns_enabled = true

  # No shared keys, no SAS. Every caller — Databricks, Airflow, CI, a human —
  # authenticates as an Entra principal and is authorised by RBAC or a Unity
  # Catalog grant. This single setting removes the most common data-platform
  # credential leak.
  shared_access_key_enabled = false

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = var.public_network_access_enabled
  allow_nested_items_to_be_public = false

  # Platform-managed encryption underneath Microsoft's own. Must be set at
  # creation; it cannot be turned on later without recreating the account,
  # which is why it is on even in sandbox where it buys little.
  infrastructure_encryption_enabled = true

  blob_properties {
    versioning_enabled  = var.enable_versioning
    change_feed_enabled = var.enable_versioning

    # Required before any lifecycle rule can tier on last access rather than on
    # creation or modification — without it the management policy is rejected
    # with MissingLastAccessTimeBasedTrackingPolicy.
    #
    # It is worth the small per-access metadata write: tiering bronze on
    # creation date would move a partition to cool while queries are still
    # hitting it, and every one of those reads then pays a retrieval charge.
    # Tiering on last access keeps working data hot and only demotes what is
    # genuinely cold.
    last_access_time_enabled = true

    delete_retention_policy {
      days = var.retention_days
    }

    container_delete_retention_policy {
      days = var.retention_days
    }
  }

  # Deny by default. The allow lists below are the only way in, and they are
  # subnet identities rather than addresses wherever possible.
  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = var.allowed_subnet_ids
    ip_rules                   = local.storage_ip_rules
  }

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, {
    component           = "data-lake"
    data-classification = "internal"
  })

  lifecycle {
    # Recreating the lake is never the right remediation for a drifted setting.
    prevent_destroy = false # sandbox is disposable; flipped to true in prod via override
  }
}

resource "azurerm_storage_container" "medallion" {
  for_each = local.containers

  name                  = each.key
  storage_account_id    = azurerm_storage_account.lake.id
  container_access_type = "private"

  metadata = {
    classification = each.value.classification
  }
}

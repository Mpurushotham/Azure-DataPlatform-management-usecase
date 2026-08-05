# =============================================================================
# Grants — least privilege expressed as layer visibility
# =============================================================================
# The access model in one sentence: readers see gold, writers see everything,
# and nobody sees the storage account.
#
#   catalog        readers  USE_CATALOG           can traverse, cannot read
#                  writers  USE_CATALOG, CREATE_SCHEMA
#
#   gold           readers  USE_SCHEMA, SELECT    the published product
#                  writers  full
#
#   bronze/silver  writers  full                  readers get nothing at all
#
# Readers being excluded from bronze and silver is the deliberate part. Those
# layers hold un-conformed and partially-cleansed data, and an analyst who
# builds a report on silver builds it on something with no contract, which
# breaks the first time an upstream schema shifts. Gold is the interface.
#
# Every principal is a group. See the note at the top of modules/identity.
# =============================================================================

locals {
  # Layers a reader may see. Everything else is writer-only.
  reader_visible_schemas = ["gold"]

  grants_enabled = var.enable_grants && (var.reader_principal != "" || var.writer_principal != "")
}

resource "databricks_grants" "catalog" {
  count = local.grants_enabled ? 1 : 0

  catalog = databricks_catalog.this.name

  dynamic "grant" {
    for_each = var.reader_principal != "" ? [var.reader_principal] : []
    content {
      principal = grant.value
      # USE_CATALOG alone grants no data access — it makes the catalog
      # traversable so a schema grant below can take effect.
      privileges = ["USE_CATALOG"]
    }
  }

  dynamic "grant" {
    for_each = var.writer_principal != "" ? [var.writer_principal] : []
    content {
      principal  = grant.value
      privileges = ["USE_CATALOG", "CREATE_SCHEMA"]
    }
  }
}

resource "databricks_grants" "schema" {
  for_each = local.grants_enabled ? var.schemas : {}

  schema = "${databricks_catalog.this.name}.${databricks_schema.this[each.key].name}"

  dynamic "grant" {
    # Readers appear only on schemas in reader_visible_schemas.
    for_each = (
      var.reader_principal != "" && contains(local.reader_visible_schemas, each.key)
      ? [var.reader_principal] : []
    )
    content {
      principal  = grant.value
      privileges = ["USE_SCHEMA", "SELECT"]
    }
  }

  dynamic "grant" {
    for_each = var.writer_principal != "" ? [var.writer_principal] : []
    content {
      principal = grant.value
      privileges = [
        "USE_SCHEMA",
        "SELECT",
        "MODIFY",
        "CREATE_TABLE",
        "CREATE_VOLUME",
        "CREATE_FUNCTION",
      ]
    }
  }
}

# ── External locations ───────────────────────────────────────────────────────
# Path-level access, granted to writers only and only on the layers they
# produce. Readers are never granted here: a reader with READ_FILES could read
# a bronze Parquet file directly and bypass the column masks and row filters
# that make gold safe to publish.
resource "databricks_grants" "external_location" {
  for_each = (
    local.grants_enabled && var.writer_principal != ""
    ? { for k, v in var.external_locations : k => v if k != "gold" }
    : {}
  )

  external_location = databricks_external_location.this[each.key].id

  grant {
    principal  = var.writer_principal
    privileges = ["READ_FILES", "WRITE_FILES"]
  }
}

# =============================================================================
# Lifecycle management — the cheapest FinOps control that exists
# =============================================================================
# Storage is the one platform cost that only ever grows, and it grows silently:
# nobody files a ticket because bronze is three years old. Tiering rules turn
# that into a bounded, predictable line item without anyone having to remember.
#
# Indicative Sweden Central list prices per GB-month:
#
#   Hot      ~EUR 0.0196     queryable, no retrieval charge
#   Cool     ~EUR 0.0104     30-day minimum, retrieval charged
#   Cold     ~EUR 0.0039     90-day minimum, higher retrieval
#   Archive  ~EUR 0.0018     180-day minimum, hours to rehydrate
#
# The rules below are deliberately conservative about archive: a table that
# gets archived and then needed for a regulatory query costs hours of
# rehydration, and that is an availability incident, not a saving.
# =============================================================================

resource "azurerm_storage_management_policy" "lake" {
  storage_account_id = azurerm_storage_account.lake.id

  # ── Landing: transient by definition ───────────────────────────────────────
  # Anything still here after 30 days was not ingested, which is a pipeline
  # failure that has already been alerted on. Keeping it costs money and widens
  # the exposure window for raw, unclassified source data.
  rule {
    name    = "landing-expire"
    enabled = true

    filters {
      prefix_match = ["landing/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = 30
      }
    }
  }

  # ── Bronze: append-only history, rarely re-read ────────────────────────────
  # Tiered on last access rather than creation, so a partition that is still
  # being queried stays hot. Retention runs to seven years to match the
  # logistics record-keeping obligation; adjust with legal, not with Terraform.
  rule {
    name    = "bronze-tier-and-retain"
    enabled = true

    filters {
      prefix_match = ["bronze/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_last_access_time_greater_than    = 30
        tier_to_archive_after_days_since_last_access_time_greater_than = 180
        delete_after_days_since_modification_greater_than              = 2555
      }

      # Old versions are a recovery mechanism, not history. Ninety days is
      # well past the point where a bad write would have been noticed.
      version {
        delete_after_days_since_creation = 90
      }
    }
  }

  # ── Silver and gold: serving layers, stay warm ─────────────────────────────
  # Never archived. Gold backs reporting, and a dashboard that fails because a
  # partition is in archive is indistinguishable from an outage to the person
  # looking at it.
  rule {
    name    = "curated-tier-cool"
    enabled = true

    filters {
      prefix_match = ["silver/", "gold/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_last_access_time_greater_than = 180
      }

      version {
        delete_after_days_since_creation = 30
      }
    }
  }

  # ── Quarantine: bounded, but long enough to investigate ────────────────────
  rule {
    name    = "quarantine-expire"
    enabled = true

    filters {
      prefix_match = ["quarantine/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_creation_greater_than = 30
        delete_after_days_since_creation_greater_than       = 180
      }
    }
  }

  # Deliberately absent: any rule touching checkpoints/. Structured Streaming
  # reads its checkpoint on every microbatch. A cool-tiered checkpoint adds
  # latency to every trigger; an archived one stops the stream entirely and the
  # failure surfaces as unexplained lag rather than as a storage error.
}

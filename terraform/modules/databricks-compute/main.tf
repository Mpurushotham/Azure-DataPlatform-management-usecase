# =============================================================================
# Databricks compute — policy is where FinOps actually happens
# =============================================================================
# A budget alert tells you that money was spent. A cluster policy stops it
# being spent. Everything expensive about Databricks is a cluster setting, so
# this is the highest-leverage file in the repo for cost:
#
#   auto-termination     an idle cluster bills at full rate
#   node type allowlist  one oversized default multiplies every job
#   max workers          a runaway autoscale can eat the regional quota
#   fixed tags           untagged DBU cannot be charged to a domain
#
# The tags are `fixed`, not `allowlist`. A user who can edit the domain tag can
# move their spend onto another team's cost centre — usually by accident, when
# cloning someone else's cluster.
# =============================================================================

locals {
  policy_prefix = "${var.name_prefix}-${var.environment}-${var.domain}"

  # Enforced on every cluster created under these policies. These four are what
  # scripts/python/finops_report.py groups by; a cluster missing them shows up
  # as unattributed spend, which in practice means nobody owns it.
  fixed_tags = {
    "custom_tags.platform"    = { type = "fixed", value = var.name_prefix }
    "custom_tags.environment" = { type = "fixed", value = var.environment }
    "custom_tags.domain"      = { type = "fixed", value = var.domain }
    "custom_tags.cost-center" = { type = "fixed", value = var.cost_center }
  }

  # The static security controls — access mode, disk encryption, log
  # destination, spot driver behaviour — come from a JSON file rather than being
  # written here.
  #
  # That file is the reviewable artefact: scripts/python/validate_policies.py
  # asserts every control in it is still present and still `fixed`, and that
  # check runs in CI without Terraform, without Azure and without credentials.
  # Keeping the controls in HCL would make them unverifiable outside a plan.
  #
  # Keys beginning with underscore are documentation, not policy, and Databricks
  # rejects unknown keys — so they are stripped here.
  base_policy_raw = jsondecode(file("${path.module}/../../../policies/databricks/base-cluster-policy.json"))
  base_policy = {
    for k, v in local.base_policy_raw : k => {
      for kk, vv in v : kk => vv if !startswith(kk, "_")
    } if !startswith(k, "_")
  }

  # Applied to both policies below. Written once because the two policies must
  # not drift apart on security settings — a job cluster with weaker isolation
  # than an interactive one is a way around the interactive controls.
  common_definition = merge(local.base_policy, local.fixed_tags, {
    "node_type_id" = {
      type         = "allowlist"
      values       = var.allowed_node_types
      defaultValue = var.default_node_type
    }

    "driver_node_type_id" = {
      type         = "allowlist"
      values       = var.allowed_node_types
      defaultValue = var.default_node_type
    }

    "autoscale.max_workers" = {
      type         = "range"
      maxValue     = var.max_workers_limit
      defaultValue = 2
    }

    # The runtime version's default comes from a variable so an environment can
    # move ahead independently; the regex that constrains it stays in the JSON
    # contract, where CI can see it.
    "spark_version" = merge(local.base_policy["spark_version"], {
      defaultValue = var.spark_version
    })
  })
}

# ── Interactive clusters ─────────────────────────────────────────────────────
# Used by humans in notebooks. The tight autotermination ceiling is the point:
# this is the compute people forget to shut down.
resource "databricks_cluster_policy" "interactive" {
  name = "${local.policy_prefix}-interactive"

  definition = jsonencode(merge(local.common_definition, {
    "autotermination_minutes" = {
      type         = "range"
      maxValue     = var.max_autotermination_minutes
      defaultValue = 20
    }

    # Single-user clusters are cheaper and simpler, but a shared interactive
    # cluster serving four analysts costs a quarter of four clusters. Allowed
    # here precisely because USER_ISOLATION above makes sharing safe.
    "num_workers" = {
      type     = "range"
      minValue = 0
      maxValue = var.max_workers_limit
    }
  }))
}

# ── Job clusters ─────────────────────────────────────────────────────────────
# Created and destroyed by a scheduled run, so autotermination barely matters.
# What matters is that spot instances are the default: a job that can be
# retried can tolerate an eviction, and spot is materially cheaper.
resource "databricks_cluster_policy" "job" {
  name = "${local.policy_prefix}-job"

  definition = jsonencode(merge(local.common_definition, {
    "autotermination_minutes" = {
      type  = "fixed"
      value = 10
    }

    # -1 bids the on-demand price: the workload takes spot capacity when it
    # exists and falls back to on-demand rather than failing. The saving is
    # opportunistic, the reliability is not sacrificed.
    "azure_attributes.availability" = {
      type         = "unlimited"
      defaultValue = "SPOT_WITH_FALLBACK_AZURE"
    }

    "azure_attributes.spot_bid_max_price" = {
      type  = "fixed"
      value = -1
    }

    # The driver stays on-demand. An evicted driver fails the whole run and
    # loses every completed task with it; an evicted worker loses one task.
    "azure_attributes.first_on_demand" = {
      type  = "fixed"
      value = 1
    }
  }))
}

# ── Serverless SQL warehouse ─────────────────────────────────────────────────
# Serverless rather than classic, and that choice is what makes this platform
# fit its quota at all: serverless compute runs in Databricks' own subscription
# and consumes none of this subscription's vCPU allowance. A classic warehouse
# would need a 4-vCPU node, which is the entire regional quota.
#
# It costs nothing while stopped. The auto-stop below is therefore the only
# cost control it needs.
resource "databricks_sql_endpoint" "this" {
  count = var.enable_sql_warehouse ? 1 : 0

  name                      = "sqlw-${local.policy_prefix}"
  cluster_size              = var.sql_warehouse_size
  auto_stop_mins            = var.sql_warehouse_auto_stop_minutes
  enable_serverless_compute = true

  # One cluster, no scale-out. This warehouse serves validation queries and
  # dashboard development, not a concurrent analyst population.
  min_num_clusters = 1
  max_num_clusters = 1

  warehouse_type = "PRO"

  tags {
    custom_tags {
      key   = "platform"
      value = var.name_prefix
    }
    custom_tags {
      key   = "environment"
      value = var.environment
    }
    custom_tags {
      key   = "domain"
      value = var.domain
    }
    custom_tags {
      key   = "cost-center"
      value = var.cost_center
    }
  }
}

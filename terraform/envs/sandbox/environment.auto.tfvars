# =============================================================================
# Environment configuration — COMMITTED, and deliberately so
# =============================================================================
# terraform.tfvars is gitignored because it carries subscription identifiers and
# the operator's own address. That is correct, and it created a worse problem:
# CI passed only three of the ten variables, so it planned against defaults for
# the rest and produced a different plan than the operator saw.
#
# Measured on a real pull request: the operator's plan said "No changes"; CI's
# said "5 to change, 1 to destroy". Had it applied, it would have removed the
# operator IP allowlist, the alert email receivers and the AKS admin group
# binding — a CI run silently degrading the platform's security posture.
#
# So the split is now explicit:
#
#   environment.auto.tfvars   committed. Configuration that describes the
#                             environment and is not sensitive. Terraform loads
#                             *.auto.tfvars automatically, in CI and locally.
#   terraform.tfvars          gitignored. Identifiers and the operator address.
#                             CI supplies the same values as TF_VAR_* from
#                             repository variables and secrets.
#
# If a value belongs to the environment rather than to the person applying it,
# it belongs here — in version control, reviewed like everything else.
# =============================================================================

# Append only. The network module allocates Databricks subnets by list index,
# so reordering renumbers existing workspaces.
domains = ["logistics"]

# In the subscription's BILLING CURRENCY — SEK here, not EUR. See the note on
# the governance module's variable of the same name.
monthly_budget    = 550
budget_start_date = "2026-08-01T00:00:00Z"

# The only component that consumes vCPU quota.
enable_aks = true

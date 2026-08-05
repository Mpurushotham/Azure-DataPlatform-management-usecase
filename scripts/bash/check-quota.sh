#!/usr/bin/env bash
# =============================================================================
# Quota preflight — will this environment fit before Terraform finds out?
# =============================================================================
# A quota failure surfaces roughly twelve minutes into an AKS create, after the
# control plane exists and while the node pool is being provisioned. Terraform
# then leaves a half-built cluster that the next apply has to reconcile.
#
# This check takes two seconds and answers the same question up front.
#
#   ./scripts/bash/check-quota.sh sandbox
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-sandbox}"
REGION="${REGION:-swedencentral}"

# What each environment asks for at its autoscaler ceiling. Kept in step with
# node_count_max and node_vm_size in the matching terraform/envs root.
case "$ENVIRONMENT" in
  sandbox) REQUIRED_VCPU=4  ;;  # 2 x Standard_B2s_v2
  prod)    REQUIRED_VCPU=24 ;;  # system + memory + spot pools
  *) echo "ERROR: unknown environment '$ENVIRONMENT'"; exit 1 ;;
esac

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not installed."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not installed."; exit 1; }

echo "Region:      $REGION"
echo "Environment: $ENVIRONMENT"
echo

usage_json=$(az vm list-usage --location "$REGION" -o json)

read -r total_used total_limit <<<"$(
  echo "$usage_json" | jq -r '
    .[] | select(.localName | test("Total Regional vCPUs"))
    | "\(.currentValue) \(.limit)"'
)"

available=$(( total_limit - total_used ))

printf 'Total regional vCPUs   used %s of %s (%s available)\n' \
  "$total_used" "$total_limit" "$available"
printf 'This environment needs %s\n\n' "$REQUIRED_VCPU"

# The B-series family has its own limit independent of the regional total.
# Being inside the regional budget and outside the family budget is a real and
# confusing failure — the error names a quota nobody was watching.
read -r fam_used fam_limit <<<"$(
  echo "$usage_json" | jq -r '
    .[] | select(.localName | test("Standard Bsv2 Family vCPUs"))
    | "\(.currentValue) \(.limit)"'
)"

if [[ -n "${fam_used:-}" ]]; then
  printf 'Standard Bsv2 family   used %s of %s\n\n' "$fam_used" "$fam_limit"
fi

if (( available < REQUIRED_VCPU )); then
  cat <<EOF
BLOCKED: $REQUIRED_VCPU vCPU required, $available available.

Options, cheapest first:
  1. Free capacity that is already yours:
       make stop ENV=$ENVIRONMENT        stops nodes, keeps the cluster
       az aks delete ...                 releases the quota entirely
  2. Deploy the data platform without compute:
       enable_aks = false in terraform/envs/$ENVIRONMENT/terraform.tfvars
     Lake, Databricks, Unity Catalog and governance all still apply — only
     Airflow and the in-cluster monitoring need a node.
  3. Request an increase (not available on Free Trial subscriptions):
       az quota update ...
EOF
  exit 1
fi

echo "OK: $REQUIRED_VCPU vCPU required, $available available."

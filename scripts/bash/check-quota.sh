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

# What this environment already consumes counts as available *to it*. Without
# this the check is wrong in the only state that matters day to day: a deployed
# environment's own nodes sit in `used`, so comparing its full ceiling against
# `available` blocks a platform that is running fine and needs no new capacity.
# The first CI apply failed exactly this way -- "BLOCKED: 4 vCPU required, 2
# available" on a healthy cluster already holding the other 2.
env_used=0
cluster_name="aks-yoda-${ENVIRONMENT}"
cluster_rg="rg-yoda-${ENVIRONMENT}-compute"

if pools=$(az aks show -g "$cluster_rg" -n "$cluster_name" \
             --query "agentPoolProfiles[].{count:count,size:vmSize}" -o json 2>/dev/null); then
  while read -r count size; do
    [[ -z "$size" || "$size" == "null" ]] && continue
    cores=$(az vm list-sizes --location "$REGION" \
              --query "[?name=='${size}'].numberOfCores | [0]" -o tsv 2>/dev/null)
    [[ -z "$cores" || "$cores" == "None" ]] && cores=0
    env_used=$(( env_used + count * cores ))
  done < <(echo "$pools" | jq -r '.[] | "\(.count) \(.size)"')
fi

effective=$(( available + env_used ))

printf 'Total regional vCPUs     used %s of %s (%s available)\n' \
  "$total_used" "$total_limit" "$available"
if (( env_used > 0 )); then
  printf 'Already held by %-8s %s (reusable by this apply)\n' "$ENVIRONMENT" "$env_used"
  printf 'Effectively available    %s\n' "$effective"
fi
printf 'This environment needs   %s\n\n' "$REQUIRED_VCPU"

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

if (( effective < REQUIRED_VCPU )); then
  cat <<EOF
BLOCKED: $REQUIRED_VCPU vCPU required, $effective effectively available
($available free, $env_used already held by this environment).

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

echo "OK: $REQUIRED_VCPU vCPU required, $effective effectively available."

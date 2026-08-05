#!/usr/bin/env bash
# =============================================================================
# Unity Catalog metastore preflight
# =============================================================================
# terraform/envs/sandbox-databricks assumes a metastore exists in the region and
# is assigned to each workspace. Azure Databricks auto-provisions one per region
# when the first workspace is created in an account, so this is usually already
# true — but "usually" is not something an apply should rely on, and the failure
# when it is not true reads as a permissions error rather than a missing
# metastore.
#
# Creating a metastore requires account-admin credentials against
# accounts.azuredatabricks.net, which a workspace-scoped provider does not have.
# That is why this is a check with instructions rather than a Terraform
# resource. See ADR-007.
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-sandbox}"
TF_DIR="terraform/envs/${ENVIRONMENT}"

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not installed."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not installed."; exit 1; }

if ! command -v databricks >/dev/null 2>&1; then
  cat <<'EOF'
The Databricks CLI is not installed, so this check cannot run.

  brew install databricks

Check manually instead: open any workspace, then Catalog in the sidebar. If a
metastore is attached you will see catalogs listed; if not, the page offers to
create one.
EOF
  exit 0
fi

workspaces=$(terraform -chdir="$TF_DIR" output -json databricks_workspaces 2>/dev/null || echo '{}')

if [[ "$workspaces" == "{}" ]]; then
  echo "ERROR: no workspace outputs found. Apply $TF_DIR first."
  exit 1
fi

failed=0

while read -r key url; do
  printf 'Workspace %-12s %s\n' "$key" "$url"

  # `unity-catalog metastores current` returns the metastore assigned to this
  # workspace, or fails when none is assigned. The distinction matters: a
  # metastore can exist in the region and still not be attached here.
  if metastore=$(DATABRICKS_HOST="$url" databricks unity-catalog metastores current 2>/dev/null); then
    name=$(echo "$metastore" | jq -r '.metastore_name // .name // "unknown"')
    id=$(echo "$metastore" | jq -r '.metastore_id // "unknown"')
    printf '  attached: %s (%s)\n\n' "$name" "$id"
  else
    printf '  NO METASTORE ASSIGNED\n\n'
    failed=1
  fi
done < <(echo "$workspaces" | jq -r 'to_entries[] | "\(.key) \(.value.url)"')

if (( failed )); then
  cat <<'EOF'
At least one workspace has no metastore.

Fix it once, as an account admin (the Entra Global Administrator is one by
default):

  1. https://accounts.azuredatabricks.net -> Catalog
  2. Create metastore, region swedencentral. Leave the storage root empty —
     this platform gives each catalog its own external location, and a
     metastore-level root would become an unmanaged default nobody chose.
  3. Assign it to every workspace in the region.

Then re-run this check and apply the sandbox-databricks root.
EOF
  exit 1
fi

echo "All workspaces have a metastore assigned."

#!/usr/bin/env bash
# =============================================================================
# Provision Entra groups into the Databricks account
# =============================================================================
# Unity Catalog grants can only name principals that exist at the *account*
# level. Entra groups do not appear there by themselves, which is why
# `enable_grants` defaults to false and why a grant naming a group that plainly
# exists in Entra fails with:
#
#   PRINCIPAL_DOES_NOT_EXIST: Could not find principal with name yoda-...
#
# There are three ways to close that gap. This script implements the third,
# because it is the only one that is scriptable end to end:
#
#   1. Automatic identity management — an account-console toggle that makes
#      every Entra identity visible to Databricks with no sync at all. Best
#      option where available; verify with `--check` below before using this.
#   2. The Entra "Azure Databricks SCIM Provisioning Connector" gallery app —
#      continuous, bidirectional, and the right answer for an organisation.
#      Requires creating an enterprise application and a SCIM token by hand.
#   3. Direct provisioning through the account SCIM API — what this does.
#      A point-in-time push of the groups and their members.
#
# Option 3 is a real synchronisation, not a workaround: it calls the same API
# the connector calls. What it does not do is stay in sync. Membership changed
# in Entra afterwards is not reflected until this runs again, so treat it as a
# bootstrap and move to option 1 or 2 for anything long-lived. That trade-off
# is recorded in docs/RUNBOOKS.md#scim-provisioning.
#
#   export DATABRICKS_ACCOUNT_ID=<uuid from the account console>
#   ./scripts/bash/setup-scim.sh              # provision
#   ./scripts/bash/setup-scim.sh --check      # report only, change nothing
# =============================================================================
set -euo pipefail

MODE="${1:-provision}"
ACCOUNT_HOST="https://accounts.azuredatabricks.net"
# Databricks' first-party Entra application. A token for this resource is what
# turns an `az login` into Databricks API access — no PAT is involved.
DATABRICKS_RESOURCE="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
GROUP_PREFIX="${GROUP_PREFIX:-yoda-}"

for cmd in az jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is not installed."; exit 1; }
done

# ── Check mode needs no account ID ───────────────────────────────────────────
# Whether Unity Catalog can resolve a principal is answerable from the
# workspace, and that is the only question that matters: automatic identity
# management, the SCIM connector and a direct push all succeed or fail on it
# identically. Probing here means the check works before any of them is set up.
if [[ "$MODE" == "--check" ]]; then
  WORKSPACE_URL="${WORKSPACE_URL:-$(terraform -chdir=terraform/envs/sandbox output -json databricks_workspaces 2>/dev/null \
    | jq -r '.central.url // empty')}"

  if [[ -z "$WORKSPACE_URL" ]]; then
    echo "ERROR: could not determine the workspace URL. Set WORKSPACE_URL, or apply terraform/envs/sandbox first."
    exit 1
  fi

  TOKEN=$(az account get-access-token --resource "$DATABRICKS_RESOURCE" --query accessToken -o tsv)
  echo "Workspace : $WORKSPACE_URL"
  echo "Probing whether Unity Catalog can resolve each Entra group."
  echo

  missing=0 resolved=0
  while read -r gname; do
    [[ -z "$gname" ]] && continue
    # A dry-run grant of USE_CATALOG on a catalog that exists. Databricks
    # validates the principal before it validates anything else, so a
    # PRINCIPAL_DOES_NOT_EXIST is a definitive answer; any other outcome means
    # the principal resolved.
    body=$(curl -sS -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      "${WORKSPACE_URL}/api/2.1/unity-catalog/permissions/catalog/${PROBE_CATALOG:-yoda_sandbox_platform}" \
      -d "{\"changes\":[{\"principal\":\"${gname}\",\"add\":[]}]}" 2>/dev/null)

    if grep -q "PRINCIPAL_DOES_NOT_EXIST" <<<"$body"; then
      printf '  [NOT VISIBLE] %s\n' "$gname"
      missing=$((missing + 1))
    else
      printf '  [resolved]    %s\n' "$gname"
      resolved=$((resolved + 1))
    fi
  done < <(az ad group list --filter "startswith(displayName,'${GROUP_PREFIX}')" \
             --query "[].displayName" -o tsv 2>/dev/null)

  echo
  if (( missing > 0 )); then
    cat <<EOF
$missing of $((missing + resolved)) group(s) are not visible to Unity Catalog.

Enable automatic identity management (no account ID, no token, no sync job):

  1. https://accounts.azuredatabricks.net
  2. Settings -> Identity management
  3. Automatic identity management -> ON

Then re-run this check. Grants stay off until it passes -- a half-applied
grant model is worse than none, which is what the enable_grants gate is for.
EOF
    exit 1
  fi

  echo "All $resolved group(s) resolve. Safe to set enable_grants = true."
  exit 0
fi

if [[ -z "${DATABRICKS_ACCOUNT_ID:-}" ]]; then
  cat <<'EOF'
ERROR: DATABRICKS_ACCOUNT_ID is not set.

The Databricks account ID is not exposed by ARM, by the workspace API, or by
the accounts API without already knowing it — it is only shown in the account
console. Find it once:

  1. https://accounts.azuredatabricks.net
  2. Sign in with the Entra account that is a Databricks account admin
     (the tenant Global Administrator is one by default)
  3. The UUID is in the address bar, and under the user menu as "Account ID"

  export DATABRICKS_ACCOUNT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

It is an identifier, not a secret, but it is not worth committing either —
keep it in your shell profile.
EOF
  exit 1
fi

TOKEN=$(az account get-access-token --resource "$DATABRICKS_RESOURCE" --query accessToken -o tsv)
SCIM="${ACCOUNT_HOST}/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}/scim/v2"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/scim+json" "${SCIM}${path}" -d "$body"
  else
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" "${SCIM}${path}"
  fi
}

# Fail fast and clearly rather than emitting confusing errors per group.
probe=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${SCIM}/Groups?count=1")
case "$probe" in
  200) : ;;
  401|403)
    echo "ERROR: HTTP $probe from the account SCIM API."
    echo "The signed-in identity is not a Databricks account admin, or the account ID is wrong."
    echo "Account admin is granted to Entra Global Administrators by default; confirm at"
    echo "  https://accounts.azuredatabricks.net -> User management -> your user -> Roles"
    exit 1 ;;
  *)
    echo "ERROR: HTTP $probe from ${SCIM}/Groups — check DATABRICKS_ACCOUNT_ID."
    exit 1 ;;
esac

echo "Databricks account : $DATABRICKS_ACCOUNT_ID"
echo "Entra groups       : ${GROUP_PREFIX}*"
echo "Mode               : $MODE"
echo

existing=$(api GET "/Groups?count=200" | jq -r '.Resources[]?.displayName' 2>/dev/null || true)

created=0 present=0 members_added=0

while read -r gid gname; do
  [[ -z "$gname" ]] && continue

  if grep -qxF "$gname" <<<"$existing"; then
    printf '  [exists] %s\n' "$gname"
    present=$((present + 1))
    dbx_group_id=$(api GET "/Groups?filter=displayName+eq+%22${gname}%22" | jq -r '.Resources[0].id // empty')
  else
    if [[ "$MODE" == "--check" ]]; then
      printf '  [MISSING] %s\n' "$gname"
      continue
    fi
    dbx_group_id=$(api POST "/Groups" "$(jq -nc --arg n "$gname" \
      '{schemas:["urn:ietf:params:scim:schemas:core:2.0:Group"],displayName:$n}')" \
      | jq -r '.id // empty')
    if [[ -z "$dbx_group_id" ]]; then
      printf '  [FAILED]  %s\n' "$gname"
      continue
    fi
    printf '  [created] %s\n' "$gname"
    created=$((created + 1))
  fi

  [[ "$MODE" == "--check" || -z "${dbx_group_id:-}" ]] && continue

  # Members are synchronised by user principal name. A user that has never
  # signed in to Databricks is created as an account user by this call, which
  # is what the SCIM connector would also do.
  while read -r upn; do
    [[ -z "$upn" ]] && continue
    user_id=$(api GET "/Users?filter=userName+eq+%22${upn}%22" | jq -r '.Resources[0].id // empty')
    if [[ -z "$user_id" ]]; then
      user_id=$(api POST "/Users" "$(jq -nc --arg u "$upn" \
        '{schemas:["urn:ietf:params:scim:schemas:core:2.0:User"],userName:$u}')" \
        | jq -r '.id // empty')
      [[ -n "$user_id" ]] && printf '      + account user %s\n' "$upn"
    fi
    [[ -z "$user_id" ]] && continue

    # PATCH add is idempotent; Databricks ignores a member already present.
    api PATCH "/Groups/${dbx_group_id}" "$(jq -nc --arg v "$user_id" \
      '{schemas:["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        Operations:[{op:"add",path:"members",value:[{value:$v}]}]}')" >/dev/null
    printf '      member %s\n' "$upn"
    members_added=$((members_added + 1))
  done < <(az ad group member list --group "$gid" --query "[].userPrincipalName" -o tsv 2>/dev/null || true)

done < <(az ad group list --filter "startswith(displayName,'${GROUP_PREFIX}')" \
           --query "[].{id:id,name:displayName}" -o tsv 2>/dev/null)

echo
if [[ "$MODE" == "--check" ]]; then
  echo "Check only — nothing was changed."
else
  echo "Created $created group(s), $present already present, $members_added membership(s) applied."
  cat <<'EOF'

Next:
  1. Confirm the groups are visible to Unity Catalog:
       ./scripts/bash/setup-scim.sh --check
  2. Turn on grants and apply:
       enable_grants = true   in terraform/envs/sandbox-databricks/terraform.tfvars
       make plan  ENV=sandbox-databricks
       make apply ENV=sandbox-databricks
  3. Verify nothing was granted outside Terraform:
       make drift ENV=sandbox

This was a point-in-time push. For continuous sync, configure the Entra
"Azure Databricks SCIM Provisioning Connector" enterprise application, or
enable automatic identity management in the account console.
EOF
fi

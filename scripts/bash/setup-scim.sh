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
#   ./scripts/bash/setup-scim.sh              # provision
#   ./scripts/bash/setup-scim.sh --check      # report only, change nothing
#
# Needs no account ID and no SCIM token -- see the note above the provisioning
# section on why the workspace proxy is used rather than accounts.azuredatabricks.net.
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

# ── Provisioning through the workspace proxy ─────────────────────────────────
# A workspace proxies the account SCIM API at /api/2.0/account/scim/v2, and an
# ordinary Azure CLI token is accepted there. That matters more than it sounds:
#
#   accounts.azuredatabricks.net/api/2.0/accounts/<id>/scim/v2
#     needs the account ID, which is only visible in the account console, and
#     rejects a token from an MSA guest identity with
#     "Failed to retrieve tenant ID for given token"
#
#   <workspace>/api/2.0/account/scim/v2
#     needs neither. Same account-level objects, reachable with the token this
#     platform already uses everywhere else.
#
# So no account ID, no SCIM token, no enterprise application, and it works for
# guest identities that cannot sign in to the account console at all.
WORKSPACE_URL="${WORKSPACE_URL:-$(terraform -chdir=terraform/envs/sandbox output -json databricks_workspaces 2>/dev/null \
  | jq -r '.central.url // empty')}"

if [[ -z "$WORKSPACE_URL" ]]; then
  echo "ERROR: could not determine the workspace URL. Set WORKSPACE_URL, or apply terraform/envs/sandbox first."
  exit 1
fi

TOKEN=$(az account get-access-token --resource "$DATABRICKS_RESOURCE" --query accessToken -o tsv)
SCIM="${WORKSPACE_URL}/api/2.0/account/scim/v2"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/scim+json" "${SCIM}${path}" -d "$body"
  else
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" "${SCIM}${path}"
  fi
}

probe=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "${SCIM}/Groups?count=1")
if [[ "$probe" != "200" ]]; then
  echo "ERROR: HTTP $probe from ${SCIM}/Groups."
  echo "The signed-in identity is not a Databricks account admin, or the workspace URL is wrong."
  exit 1
fi

echo "Workspace    : $WORKSPACE_URL"
echo "Entra groups : ${GROUP_PREFIX}*"
echo

first_id() { python3 -c "import json,sys;r=json.load(sys.stdin).get('Resources',[]);print(r[0]['id'] if r else '')" 2>/dev/null; }

# A guest is stored in Entra as user_domain#EXT#@tenant but Databricks knows it
# by the real address. Reconstructing it needs the FIRST underscore replaced,
# not the last -- getting that wrong creates a plausible-looking account user
# that matches nothing.
real_upn() {
  case "$1" in
    *"#EXT#"*) echo "${1%%#EXT#*}" | sed 's/_/@/' ;;
    *) echo "$1" ;;
  esac
}

created=0 present=0 members=0

while read -r grp; do
  [[ -z "$grp" ]] && continue

  grp_id=$(api GET "/Groups?filter=displayName+eq+%22${grp}%22" | first_id)
  if [[ -z "$grp_id" ]]; then
    grp_id=$(api POST "/Groups" "$(jq -nc --arg n "$grp" \
      '{schemas:["urn:ietf:params:scim:schemas:core:2.0:Group"],displayName:$n}')" \
      | jq -r '.id // empty')
    [[ -z "$grp_id" ]] && { printf '  [FAILED]  %s\n' "$grp"; continue; }
    printf '  [created] %s\n' "$grp"
    created=$((created + 1))
  else
    printf '  [exists]  %s\n' "$grp"
    present=$((present + 1))
  fi

  while read -r raw; do
    [[ -z "$raw" ]] && continue
    upn=$(real_upn "$raw")
    user_id=$(api GET "/Users?filter=userName+eq+%22${upn}%22" | first_id)
    if [[ -z "$user_id" ]]; then
      user_id=$(api POST "/Users" "$(jq -nc --arg u "$upn" \
        '{schemas:["urn:ietf:params:scim:schemas:core:2.0:User"],userName:$u}')" \
        | jq -r '.id // empty')
      [[ -n "$user_id" ]] && printf '      created account user %s\n' "$upn"
    fi
    [[ -z "$user_id" ]] && { printf '      ! unresolved %s\n' "$raw"; continue; }

    api PATCH "/Groups/${grp_id}" "$(jq -nc --arg v "$user_id" \
      '{schemas:["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        Operations:[{op:"add",path:"members",value:[{value:$v}]}]}')" >/dev/null
    printf '      + %s\n' "$upn"
    members=$((members + 1))
  done < <(az ad group member list --group "$grp" --query "[].userPrincipalName" -o tsv 2>/dev/null || true)

done < <(az ad group list --filter "startswith(displayName,'${GROUP_PREFIX}')" \
           --query "[].displayName" -o tsv 2>/dev/null)

cat <<EOF

Created $created group(s), $present already present, $members membership(s) applied.

Next:
  ./scripts/bash/setup-scim.sh --check      confirm Unity Catalog resolves them
  enable_grants = true                      terraform/envs/sandbox-databricks
  make apply ENV=sandbox-databricks
  make drift ENV=sandbox                    should report no drift

Point-in-time. Re-run after Entra membership changes, or configure the Entra
SCIM connector for continuous sync.
EOF

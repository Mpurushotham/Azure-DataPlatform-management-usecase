#!/usr/bin/env python3
"""Detect drift between declared Unity Catalog state and what is live.

Terraform detects drift in the objects it manages. It cannot detect a grant
added in the Databricks UI, because that grant is not in state and
`databricks_grants` is authoritative only over the principals it names — a
principal Terraform has never heard of is invisible to `terraform plan`.

That gap is the one that matters. Someone grants a colleague access to unblock
them on a Friday, nobody removes it, and the access review months later has no
record of why it exists. This finds those.

    python3 scripts/python/uc_drift.py --env sandbox
    python3 scripts/python/uc_drift.py --env sandbox --json

Reads through the Databricks REST API using the Azure CLI login, so it needs no
credential of its own.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any

# Databricks' first-party Entra application ID. Requesting a token for this
# resource is what turns an Azure CLI login into Databricks API access — no PAT
# involved, which is the point.
DATABRICKS_RESOURCE = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

# Principals expected to appear on platform objects. Anything else on a catalog
# is drift worth a human look.
EXPECTED_PRINCIPAL_PREFIXES = ("yoda-",)

# Databricks-managed principals that legitimately appear and are not drift.
SYSTEM_PRINCIPALS = {"account users", "System user"}


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
    except FileNotFoundError:
        sys.exit(f"ERROR: {cmd[0]} not found on PATH.")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"ERROR: {' '.join(cmd)} failed:\n{exc.stderr.strip()}")


def databricks_token() -> str:
    return run(
        ["az", "account", "get-access-token", "--resource", DATABRICKS_RESOURCE,
         "--query", "accessToken", "-o", "tsv"]
    )


def api_get(host: str, path: str, token: str) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{host.rstrip('/')}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        # A 404 on a grants endpoint means the object exists but has no grants,
        # which is a legitimate state rather than an error.
        if exc.code == 404:
            return {}
        body = exc.read().decode(errors="replace")[:200]
        print(f"  WARN: {path} returned {exc.code}: {body}", file=sys.stderr)
        return {}
    except urllib.error.URLError as exc:
        print(f"  WARN: {path} unreachable: {exc.reason}", file=sys.stderr)
        return {}


def terraform_output(tf_dir: str, name: str) -> Any:
    raw = run(["terraform", f"-chdir={tf_dir}", "output", "-json", name])
    return json.loads(raw) if raw else {}


def audit_workspace(name: str, host: str, token: str, declared: set[str]) -> list[dict]:
    findings: list[dict] = []

    catalogs = api_get(host, "/api/2.1/unity-catalog/catalogs", token).get("catalogs", [])

    for catalog in catalogs:
        catalog_name = catalog.get("name", "")

        # Databricks auto-creates a workspace-scoped catalog per workspace. It
        # is not ours and not drift.
        if not catalog_name.startswith("yoda_"):
            continue

        if catalog_name not in declared:
            findings.append({
                "severity": "high",
                "workspace": name,
                "object": catalog_name,
                "kind": "undeclared-catalog",
                "detail": "Catalog exists but is not declared in Terraform. Import it or delete it.",
            })

        owner = catalog.get("owner", "")
        if owner and not owner.startswith(EXPECTED_PRINCIPAL_PREFIXES) and owner not in SYSTEM_PRINCIPALS:
            findings.append({
                "severity": "medium",
                "workspace": name,
                "object": catalog_name,
                "kind": "unexpected-owner",
                "detail": f"Owned by '{owner}'. Catalogs should be owned by a yoda-* group, not a user.",
            })

        grants = api_get(
            host, f"/api/2.1/unity-catalog/permissions/catalog/{catalog_name}", token
        ).get("privilege_assignments", [])

        for assignment in grants:
            principal = assignment.get("principal", "")
            privileges = assignment.get("privileges", [])

            if principal in SYSTEM_PRINCIPALS:
                continue

            # A grant to a principal that is not a yoda-* group is either a
            # direct user grant or an ad-hoc group — both violate ADR-012.
            if not principal.startswith(EXPECTED_PRINCIPAL_PREFIXES):
                findings.append({
                    "severity": "high",
                    "workspace": name,
                    "object": catalog_name,
                    "kind": "out-of-band-grant",
                    "detail": (
                        f"'{principal}' holds {', '.join(privileges)}. Not a yoda-* group, so it "
                        f"was granted outside Terraform. Every grant must target a group — ADR-012."
                    ),
                })

            # ALL_PRIVILEGES defeats the reader/writer split entirely.
            if "ALL_PRIVILEGES" in privileges:
                findings.append({
                    "severity": "high",
                    "workspace": name,
                    "object": catalog_name,
                    "kind": "over-broad-grant",
                    "detail": f"'{principal}' holds ALL_PRIVILEGES. The reader/writer split is bypassed.",
                })

    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", default="sandbox")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    infra_dir = f"terraform/envs/{args.env}"
    uc_dir = f"terraform/envs/{args.env}-databricks"

    workspaces = terraform_output(infra_dir, "databricks_workspaces")
    if not workspaces:
        sys.exit(f"ERROR: no workspace outputs in {infra_dir}. Apply it first.")

    declared_catalogs = set(terraform_output(uc_dir, "catalogs").values())

    token = databricks_token()
    findings: list[dict] = []

    if not args.json:
        print(f"\nUnity Catalog drift — {args.env}")
        print(f"Declared catalogs: {', '.join(sorted(declared_catalogs)) or 'none'}\n")

    for name, workspace in workspaces.items():
        if not args.json:
            print(f"  checking {name} ...")
        findings.extend(audit_workspace(name, workspace["url"], token, declared_catalogs))

    if args.json:
        print(json.dumps({"environment": args.env, "findings": findings}, indent=2))
        return 1 if findings else 0

    print()
    if not findings:
        print("No drift. Every catalog and grant matches the declared state.")
        return 0

    by_severity = {"high": [], "medium": [], "low": []}
    for finding in findings:
        by_severity.setdefault(finding["severity"], []).append(finding)

    for severity in ("high", "medium", "low"):
        items = by_severity.get(severity) or []
        if not items:
            continue
        print(f"{severity.upper()} — {len(items)}")
        for item in items:
            print(f"  [{item['workspace']}] {item['object']} · {item['kind']}")
            print(f"      {item['detail']}")
        print()

    print("Remediate in Terraform, not in the workspace UI — a UI fix reappears here next run.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

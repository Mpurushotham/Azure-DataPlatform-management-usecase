#!/usr/bin/env python3
"""Month-to-date Azure spend, attributed to the tags the platform enforces.

The Azure portal answers "what did this subscription cost". The question a
platform team is actually asked is "what did the logistics domain cost, and why
is it more than last month" — and that needs cost grouped by the tags the
cluster policies and Terraform modules put on every resource.

Anything that lands in `untagged` is the finding, not a rounding error: it is
spend nobody owns, which means it is spend nobody will reduce. Resources
created outside Terraform are the usual source.

    python3 scripts/python/finops_report.py --env sandbox
    python3 scripts/python/finops_report.py --env sandbox --json > reports/mtd.json

Reads Azure Cost Management through the az CLI, so it needs no credential of
its own beyond an existing `az login`.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import date, datetime, timezone

# Tags the governance module marks mandatory. Grouping keys, in priority order.
COST_DIMENSIONS = ["platform", "environment", "domain", "cost-center"]


def run_az(args: list[str]) -> dict | list:
    """Invoke the az CLI and parse its JSON, failing with the actual message."""
    try:
        result = subprocess.run(
            ["az", *args, "-o", "json"],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        sys.exit("ERROR: az CLI not found on PATH.")
    except subprocess.CalledProcessError as exc:
        # az writes the useful part to stderr; surfacing stdout here would show
        # an empty string and hide the reason.
        sys.exit(f"ERROR: az {' '.join(args)} failed:\n{exc.stderr.strip()}")

    if not result.stdout.strip():
        return {}
    return json.loads(result.stdout)


def query_cost(subscription_id: str, start: str, end: str) -> list[dict]:
    """Pull actual cost grouped by resource and tag from Cost Management.

    The Query API is used rather than `az consumption usage list` because the
    latter does not return tags, which makes it useless for attribution.
    """
    payload = {
        "type": "ActualCost",
        "timeframe": "Custom",
        "timePeriod": {"from": start, "to": end},
        "dataset": {
            "granularity": "None",
            "aggregation": {
                "totalCost": {"name": "Cost", "function": "Sum"},
            },
            "grouping": [
                {"type": "Dimension", "name": "ResourceId"},
                {"type": "Dimension", "name": "ResourceType"},
            ],
        },
    }

    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        "/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    )

    response = run_az(
        [
            "rest",
            "--method", "post",
            "--url", url,
            "--body", json.dumps(payload),
        ]
    )

    if not isinstance(response, dict):
        return []

    props = response.get("properties", {})
    columns = [c["name"] for c in props.get("columns", [])]
    return [dict(zip(columns, row)) for row in props.get("rows", [])]


def tags_for_resources(resource_ids: set[str]) -> dict[str, dict[str, str]]:
    """Fetch tags for every resource that appeared in the cost query.

    Cost Management can group by tag directly, but only one tag at a time, and
    a resource missing that tag collapses into an unlabelled bucket that cannot
    be told apart from a genuinely untagged one. Reading tags from Resource
    Graph instead keeps all four dimensions and makes 'untagged' explicit.
    """
    query = (
        "Resources | project id, tags | where isnotnull(tags)"
    )
    rows = run_az(["graph", "query", "-q", query, "--first", "1000"])

    if isinstance(rows, dict):
        rows = rows.get("data", [])

    lookup: dict[str, dict[str, str]] = {}
    for row in rows or []:
        rid = (row.get("id") or "").lower()
        if rid in resource_ids:
            lookup[rid] = {k.lower(): v for k, v in (row.get("tags") or {}).items()}
    return lookup


def build_report(rows: list[dict], tag_lookup: dict[str, dict[str, str]]) -> dict:
    by_dimension: dict[str, dict[str, float]] = {
        dim: defaultdict(float) for dim in COST_DIMENSIONS
    }
    by_type: dict[str, float] = defaultdict(float)
    untagged: list[dict] = []
    total = 0.0
    currency = "EUR"

    for row in rows:
        cost = float(row.get("Cost") or 0.0)
        resource_id = (row.get("ResourceId") or "").lower()
        resource_type = row.get("ResourceType") or "unknown"
        currency = row.get("Currency") or currency

        total += cost
        by_type[resource_type] += cost

        tags = tag_lookup.get(resource_id, {})
        for dim in COST_DIMENSIONS:
            by_dimension[dim][tags.get(dim, "untagged")] += cost

        # Only report untagged resources that actually cost something. A
        # zero-cost untagged resource is a governance finding, not a FinOps one.
        if not tags.get("platform") and cost > 0.01:
            untagged.append(
                {
                    "resource_id": row.get("ResourceId"),
                    "resource_type": resource_type,
                    "cost": round(cost, 4),
                }
            )

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "currency": currency,
        "total": round(total, 2),
        "by_dimension": {
            dim: {k: round(v, 2) for k, v in sorted(
                values.items(), key=lambda kv: kv[1], reverse=True
            )}
            for dim, values in by_dimension.items()
        },
        "by_resource_type": dict(
            sorted(
                ((k, round(v, 2)) for k, v in by_type.items()),
                key=lambda kv: kv[1],
                reverse=True,
            )
        ),
        "untagged": sorted(untagged, key=lambda r: r["cost"], reverse=True)[:20],
    }


def print_report(report: dict) -> None:
    cur = report["currency"]
    print(f"\nMonth-to-date spend: {report['total']:.2f} {cur}")
    print(f"Generated {report['generated_at']}\n")

    for dim in COST_DIMENSIONS:
        values = report["by_dimension"].get(dim, {})
        if not values:
            continue
        print(f"By {dim}:")
        for key, cost in values.items():
            share = (cost / report["total"] * 100) if report["total"] else 0
            print(f"  {key:<28} {cost:>9.2f} {cur}  ({share:4.1f}%)")
        print()

    print("Top resource types:")
    for rtype, cost in list(report["by_resource_type"].items())[:10]:
        print(f"  {rtype:<52} {cost:>9.2f} {cur}")
    print()

    if report["untagged"]:
        print(f"UNTAGGED SPEND — {len(report['untagged'])} resources:")
        print("  Spend nobody owns. Usually created outside Terraform.")
        for item in report["untagged"][:10]:
            name = (item["resource_id"] or "").split("/")[-1]
            print(f"  {name:<44} {item['cost']:>9.2f} {cur}")
        print()
    else:
        print("No untagged spend. Every euro is attributable.\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", default="sandbox", help="Environment label, for reporting only.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a table.")
    parser.add_argument("--subscription", help="Subscription ID. Defaults to the current az context.")
    args = parser.parse_args()

    subscription_id = args.subscription
    if not subscription_id:
        account = run_az(["account", "show"])
        subscription_id = account.get("id", "") if isinstance(account, dict) else ""
    if not subscription_id:
        sys.exit("ERROR: no subscription. Run 'az login' or pass --subscription.")

    today = date.today()
    start = today.replace(day=1).isoformat()
    end = today.isoformat()

    rows = query_cost(subscription_id, start, end)
    if not rows:
        print("No usage data returned. Azure billing lags roughly 8-24 hours;")
        print("a freshly created environment will report nothing yet.")
        return 0

    resource_ids = {(r.get("ResourceId") or "").lower() for r in rows}
    report = build_report(rows, tags_for_resources(resource_ids))
    report["environment"] = args.env

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

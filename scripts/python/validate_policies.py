#!/usr/bin/env python3
"""Assert the Databricks cluster-policy security contract.

Cluster policies are the highest-leverage cost and security control on this
platform — everything expensive or dangerous about Databricks is a cluster
setting. This check makes the contract testable without Terraform and without
an Azure subscription, so it runs on every pull request in seconds.

It fails the build when a control is removed, weakened from `fixed` to
something editable, or silently changed to a different value. All three are
easy to do by accident and none are visible in a Terraform plan diff that a
reviewer skims.

    python3 scripts/python/validate_policies.py policies/
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# The contract. Each entry is a control that must exist, the policy type it must
# have, and — where the value itself is load-bearing — what it must be.
#
# `None` for expected_value means "any value, but it must be locked".
REQUIRED_CONTROLS: dict[str, dict] = {
    "data_security_mode": {
        "type": "fixed",
        "value": "USER_ISOLATION",
        "rationale": "Weaker access modes bypass Unity Catalog row filters and column masks.",
    },
    "enable_local_disk_encryption": {
        "type": "fixed",
        "value": True,
        "rationale": "Spark spills shuffle data containing customer records to local disk.",
    },
    "azure_attributes.first_on_demand": {
        "type": "fixed",
        "value": 1,
        "rationale": "An evicted spot driver fails the entire run.",
    },
    "cluster_log_conf.path": {
        "type": "fixed",
        "value": None,
        "rationale": "Without durable cluster logs, a failed job's stderr dies with the cluster.",
    },
    "spark_version": {
        "type": "regex",
        "value": None,
        "rationale": "An unconstrained runtime version means every cluster can differ.",
    },
}


def validate_policy(path: Path) -> list[str]:
    """Return a list of failures for one policy file. Empty means it passed."""
    failures: list[str] = []

    try:
        policy = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        return [f"{path}: not valid JSON — {exc}"]

    if not isinstance(policy, dict):
        return [f"{path}: expected a JSON object at the top level"]

    for control, expected in REQUIRED_CONTROLS.items():
        if control not in policy:
            failures.append(
                f"{path}: missing control '{control}'\n"
                f"    why it matters: {expected['rationale']}"
            )
            continue

        actual = policy[control]
        if not isinstance(actual, dict):
            failures.append(f"{path}: '{control}' must be an object, got {type(actual).__name__}")
            continue

        actual_type = actual.get("type")
        if actual_type != expected["type"]:
            failures.append(
                f"{path}: '{control}' has type '{actual_type}', expected '{expected['type']}'\n"
                f"    why it matters: {expected['rationale']}"
            )
            continue

        if expected["value"] is not None and actual.get("value") != expected["value"]:
            failures.append(
                f"{path}: '{control}' is {actual.get('value')!r}, expected {expected['value']!r}\n"
                f"    why it matters: {expected['rationale']}"
            )

    # A control that exists but is editable is worse than one that is absent:
    # it reads as enforced in review and is not.
    for control, definition in policy.items():
        if control.startswith("_") or not isinstance(definition, dict):
            continue
        if control in REQUIRED_CONTROLS and definition.get("type") in ("unlimited", "allowlist"):
            if REQUIRED_CONTROLS[control]["type"] == "fixed":
                failures.append(
                    f"{path}: '{control}' is '{definition.get('type')}' but must be 'fixed'"
                )

    return failures


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "policies")

    if not root.exists():
        print(f"ERROR: {root} does not exist.")
        return 1

    policy_files = sorted(root.rglob("*.json"))
    if not policy_files:
        print(f"ERROR: no policy JSON found under {root}.")
        return 1

    all_failures: list[str] = []
    for path in policy_files:
        failures = validate_policy(path)
        status = "FAIL" if failures else "ok"
        print(f"  [{status:>4}] {path}")
        all_failures.extend(failures)

    print()
    if all_failures:
        print(f"{len(all_failures)} policy contract violation(s):\n")
        for failure in all_failures:
            print(f"  {failure}")
        print()
        return 1

    print(f"{len(policy_files)} policy file(s) satisfy the security contract.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Import-check every Airflow DAG without needing an Airflow installation.

A broken DAG does not fail loudly. The scheduler logs an import error and moves
on, so the DAG simply never appears in the UI — and the first anyone notices is
that a table stopped being produced. That is an expensive way to find a typo.

When Airflow is importable this does a real import and additionally checks for
cycles, duplicate DAG ids and missing owners. When it is not — the usual case in
CI, where installing Airflow to lint a DAG is disproportionate — it falls back
to AST analysis, which still catches syntax errors, duplicate ids and the
`catchup=True` mistake that launches one run per missed interval on first
unpause.

    python3 scripts/python/validate_dags.py dags/
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path


def check_with_ast(path: Path) -> tuple[list[str], str | None]:
    """Parse without executing. Returns (failures, dag_id)."""
    failures: list[str] = []
    dag_id: str | None = None

    source = path.read_text()
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        return [f"{path}:{exc.lineno}: syntax error — {exc.msg}"], None

    for node in ast.walk(tree):
        # Both the @dag decorator and the DAG(...) constructor.
        if not isinstance(node, ast.Call):
            continue

        func = node.func
        name = getattr(func, "id", None) or getattr(func, "attr", None)
        if name not in ("dag", "DAG"):
            continue

        for kw in node.keywords:
            if kw.arg == "dag_id" and isinstance(kw.value, ast.Constant):
                dag_id = kw.value.value

            # catchup defaults to True in Airflow. With a start_date in the
            # past that means one run per missed interval the moment the DAG is
            # unpaused — on a platform with a spending limit, an expensive
            # surprise. Requiring it to be explicit is the cheap fix.
            if kw.arg == "catchup" and isinstance(kw.value, ast.Constant):
                if kw.value.value is True:
                    failures.append(
                        f"{path}: catchup=True. On first unpause this launches one run per "
                        f"missed interval since start_date. Set it False unless a backfill "
                        f"is genuinely intended."
                    )

    if dag_id is None:
        failures.append(f"{path}: no dag_id found — is this file actually a DAG?")

    if "catchup" not in source:
        failures.append(
            f"{path}: catchup is not set explicitly. It defaults to True, which backfills "
            f"every interval since start_date."
        )

    return failures, dag_id


def check_with_airflow(path: Path) -> list[str]:
    """Real import through Airflow's DagBag, when Airflow is available."""
    from airflow.models import DagBag  # noqa: PLC0415

    bag = DagBag(dag_folder=str(path.parent), include_examples=False)
    failures = [f"{file}: {err}" for file, err in bag.import_errors.items()]

    for dag_id, dag in bag.dags.items():
        if not dag.owner or dag.owner == "airflow":
            failures.append(f"{dag_id}: no owner set. An unowned DAG has nobody to page.")
        if not dag.tags:
            failures.append(f"{dag_id}: no tags. Tags are how DAGs are filtered once there are dozens.")

    return failures


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "dags")

    if not root.exists():
        print(f"ERROR: {root} does not exist.")
        return 1

    dag_files = sorted(p for p in root.rglob("*.py") if not p.name.startswith("_"))
    if not dag_files:
        print(f"No DAG files under {root}. Nothing to check.")
        return 0

    try:
        import airflow  # noqa: F401,PLC0415
        have_airflow = True
    except ImportError:
        have_airflow = False

    mode = "DagBag import" if have_airflow else "AST analysis (Airflow not installed)"
    print(f"Checking {len(dag_files)} DAG file(s) — {mode}\n")

    all_failures: list[str] = []
    seen_ids: dict[str, Path] = {}

    for path in dag_files:
        failures, dag_id = check_with_ast(path)

        if dag_id:
            if dag_id in seen_ids:
                failures.append(
                    f"{path}: duplicate dag_id '{dag_id}', already defined in {seen_ids[dag_id]}. "
                    f"Airflow silently keeps only one."
                )
            else:
                seen_ids[dag_id] = path

        status = "FAIL" if failures else "ok"
        print(f"  [{status:>4}] {path}  {f'({dag_id})' if dag_id else ''}")
        all_failures.extend(failures)

    if have_airflow:
        all_failures.extend(check_with_airflow(root / "x"))

    print()
    if all_failures:
        print(f"{len(all_failures)} problem(s):\n")
        for failure in all_failures:
            print(f"  {failure}")
        print()
        return 1

    print(f"{len(dag_files)} DAG file(s) valid, {len(seen_ids)} unique dag_id(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

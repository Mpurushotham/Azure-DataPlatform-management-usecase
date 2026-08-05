"""Logistics medallion pipeline: landing -> bronze -> silver -> gold.

The shape of this DAG is the point, more than the transformations in it.

Airflow orchestrates and Databricks computes. Every task here either waits on
something or asks Databricks to do work — no task processes data in the worker
pod. That is what lets the whole orchestration layer run on 2 vCPU alongside
Prometheus and Grafana.

Two Airflow features carry that design:

  deferrable=True     the task releases its worker pod while the Databricks run
                      executes and resumes on the triggerer. A four-hour job
                      occupies no pod for four hours. Without it, two concurrent
                      runs would saturate this node.

  job cluster policy  the cluster is created per run under the Terraform-managed
                      policy, so it inherits spot instances, the node-type
                      allowlist and the cost-attribution tags. A cluster created
                      outside the policy is untagged spend.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow.decorators import dag, task
from airflow.providers.databricks.operators.databricks import (
    DatabricksSubmitRunOperator,
)
from airflow.providers.microsoft.azure.sensors.wasb import WasbPrefixSensor

DOMAIN = "logistics"
CATALOG = os.environ.get("YODA_CATALOG_LOGISTICS", "yoda_sandbox_logistics")
JOB_POLICY_ID = os.environ.get("YODA_JOB_POLICY_ID", "")
NOTEBOOK_ROOT = "/Repos/platform/yoda-data-platform/notebooks"

# Spark version and node type must satisfy the cluster policy, which is the
# authority. Values that violate it fail at submit with a policy error rather
# than producing an unexpectedly expensive cluster.
JOB_CLUSTER = {
    "spark_version": "15.4.x-scala2.12",
    "node_type_id": "Standard_D4ads_v5",
    "num_workers": 1,
    "policy_id": JOB_POLICY_ID,
    "data_security_mode": "USER_ISOLATION",
}

default_args = {
    "owner": "data-platform-team",
    # Retries only help transient failures. Three is enough to ride out a spot
    # eviction or a control-plane blip; beyond that the job is broken and
    # retrying just delays the alert.
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
    "depends_on_past": False,
}


@dag(
    dag_id="logistics_medallion",
    description="Landing to gold for the logistics domain, executed on Databricks.",
    schedule="0 2 * * *",
    start_date=datetime(2026, 8, 1),
    # No backfill on deploy. A DAG with a start_date in the past and catchup on
    # launches one run per missed interval the moment it is unpaused — which on
    # a platform with a spending limit is a genuinely expensive mistake.
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["domain:logistics", "layer:medallion", "owner:data-platform"],
    doc_md=__doc__,
)
def logistics_medallion() -> None:
    # Arrival check rather than a fixed delay. A schedule that assumes the
    # upstream drop has landed by 02:00 produces an empty bronze table on the
    # morning it lands at 02:10, and nobody notices until a report is wrong.
    wait_for_drop = WasbPrefixSensor(
        task_id="wait_for_source_drop",
        container_name="landing",
        prefix=f"{DOMAIN}/shipments/dt={{{{ ds }}}}/",
        wasb_conn_id="wasb_lake",
        # Deferrable so the sensor holds no worker pod while it waits.
        deferrable=True,
        poke_interval=300,
        timeout=60 * 60 * 4,
        # Fail the run rather than skip. A missing drop is an upstream incident
        # and should page, not pass silently.
        soft_fail=False,
    )

    ingest_bronze = DatabricksSubmitRunOperator(
        task_id="ingest_bronze",
        new_cluster=JOB_CLUSTER,
        notebook_task={
            "notebook_path": f"{NOTEBOOK_ROOT}/bronze_ingest",
            "base_parameters": {
                "catalog": CATALOG,
                "domain": DOMAIN,
                "run_date": "{{ ds }}",
            },
        },
        deferrable=True,
    )

    build_silver = DatabricksSubmitRunOperator(
        task_id="build_silver",
        new_cluster=JOB_CLUSTER,
        notebook_task={
            "notebook_path": f"{NOTEBOOK_ROOT}/silver_conform",
            "base_parameters": {
                "catalog": CATALOG,
                "domain": DOMAIN,
                "run_date": "{{ ds }}",
            },
        },
        deferrable=True,
    )

    # Quality gate between silver and gold, not after gold. Publishing a bad
    # gold table and alerting afterwards means consumers have already read it —
    # the whole reason gold is the published interface is that it is the layer
    # something is checked before entering.
    quality_gate = DatabricksSubmitRunOperator(
        task_id="quality_gate",
        new_cluster=JOB_CLUSTER,
        notebook_task={
            "notebook_path": f"{NOTEBOOK_ROOT}/quality_checks",
            "base_parameters": {
                "catalog": CATALOG,
                "schema": "silver",
                "run_date": "{{ ds }}",
                # Rows failing a check are written to the quarantine container
                # rather than dropped, so a failure can be investigated instead
                # of merely counted.
                "quarantine_on_failure": "true",
            },
        },
        deferrable=True,
    )

    publish_gold = DatabricksSubmitRunOperator(
        task_id="publish_gold",
        new_cluster=JOB_CLUSTER,
        notebook_task={
            "notebook_path": f"{NOTEBOOK_ROOT}/gold_publish",
            "base_parameters": {
                "catalog": CATALOG,
                "domain": DOMAIN,
                "run_date": "{{ ds }}",
            },
        },
        deferrable=True,
    )

    @task(task_id="record_freshness")
    def record_freshness() -> dict[str, str]:
        """Emit the freshness marker the staleness alert reads.

        The alert is defined on absence: if this marker has not been written
        within the SLO window, gold is stale and a report is wrong right now.
        Alerting on the absence of success rather than on the presence of
        failure is what catches the DAG that never ran at all — the failure
        mode a task-failure alert is structurally blind to.
        """
        from airflow.operators.python import get_current_context

        context = get_current_context()
        return {
            "domain": DOMAIN,
            "catalog": CATALOG,
            "layer": "gold",
            "run_date": str(context["ds"]),
            "logical_date": context["logical_date"].isoformat(),
        }

    (
        wait_for_drop
        >> ingest_bronze
        >> build_silver
        >> quality_gate
        >> publish_gold
        >> record_freshness()
    )


logistics_medallion()

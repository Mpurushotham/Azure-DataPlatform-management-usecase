# =============================================================================
# Airflow image — providers baked in, not installed at pod start
# =============================================================================
# The upstream image plus _PIP_ADDITIONAL_REQUIREMENTS is the documented quick
# path and it is wrong for anything that has to run twice the same way: it
# resolves PyPI on every pod start, so a task pod's dependency set depends on
# what PyPI served that second, and a KubernetesExecutor starts a pod per task.
#
# Pinned by digest in the Helm values, not by tag. A tag is a moving pointer;
# the digest is what actually ran.
# =============================================================================

ARG AIRFLOW_VERSION=2.10.5
ARG PYTHON_VERSION=3.12

FROM apache/airflow:${AIRFLOW_VERSION}-python${PYTHON_VERSION}

# Constraints are what make an Airflow image reproducible. Without them pip is
# free to resolve a provider's transitive dependency to a version Airflow's own
# pin conflicts with, and the failure appears at DAG import rather than build.
ARG AIRFLOW_VERSION
ARG PYTHON_VERSION
ARG CONSTRAINT_URL=https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt

USER airflow

COPY docker/airflow/requirements.txt /tmp/requirements.txt

RUN pip install --no-cache-dir --constraint "${CONSTRAINT_URL}" -r /tmp/requirements.txt

# Fail the build rather than the first DAG run if a provider did not land.
RUN python -c "import airflow.providers.databricks; import azure.identity; print('providers ok')"

# DAGs are baked into the image rather than pulled at runtime by git-sync.
#
# Both routes enforce the same rule — the repository is the only way a DAG
# reaches production — but baking them in is the stricter of the two:
#
#   immutable        the image and its DAGs are one versioned artefact, so a
#                    rollback restores the exact DAG set that ran
#   no runtime dep   the scheduler does not need to reach GitHub to start; a
#                    GitHub outage cannot stop a cluster recovering
#   scannable        the DAGs are inside the image Trivy scans
#
# The cost is that changing a DAG needs an image build and a rollout rather than
# a 60-second sync. That is the right trade for a platform whose DAGs change far
# less often than its data does.
#
# The build context is the repository root, not docker/airflow — see
# scripts/bash/deploy-platform.sh.
COPY dags/ ${AIRFLOW_HOME}/dags/

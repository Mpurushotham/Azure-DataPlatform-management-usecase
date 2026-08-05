#!/usr/bin/env bash
# =============================================================================
# Deploy the in-cluster platform: monitoring, then Airflow
# =============================================================================
# Terraform owns Azure. Helm owns what runs inside the cluster. The boundary is
# deliberate — a Helm release managed through Terraform's helm provider couples
# a chart upgrade to a Terraform state lock, so a failed chart render blocks
# every unrelated infrastructure change until someone unlocks it.
#
# Every value this script substitutes comes from `terraform output`. Nothing is
# hardcoded, and no secret is written to a values file — passwords are generated
# here and applied as Kubernetes secrets.
#
#   ./scripts/bash/deploy-platform.sh sandbox
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-sandbox}"
TF_DIR="terraform/envs/${ENVIRONMENT}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

AIRFLOW_CHART_VERSION="${AIRFLOW_CHART_VERSION:-1.15.0}"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-65.1.1}"
AIRFLOW_IMAGE_TAG="${AIRFLOW_IMAGE_TAG:-2.10.5}"

for cmd in kubectl helm terraform az; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not installed."; exit 1; }
done

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || echo ""; }

ACR_LOGIN_SERVER=$(tf_out acr_login_server)
AIRFLOW_CLIENT_ID=$(tf_out airflow_identity_client_id)

[[ -n "$ACR_LOGIN_SERVER"  ]] || { echo "ERROR: acr_login_server not in outputs. Apply $TF_DIR first."; exit 1; }
[[ -n "$AIRFLOW_CLIENT_ID" ]] || { echo "ERROR: airflow_identity_client_id not in outputs."; exit 1; }

ACR_NAME="${ACR_LOGIN_SERVER%%.*}"

echo "Environment : $ENVIRONMENT"
echo "Registry    : $ACR_LOGIN_SERVER"
echo "Airflow MI  : $AIRFLOW_CLIENT_ID"
echo

# ── 1. Namespaces, Pod Security levels and NetworkPolicy ─────────────────────
# Applied before anything else: the default-deny policy must exist before the
# first pod, or there is a window where a pod is unprotected.
echo "==> Namespaces and network policy"
kubectl apply -f kubernetes/platform/namespaces.yaml

# The ServiceAccount is the subject of the Entra federated credential, so it is
# owned here rather than by the Helm chart — see kubernetes/airflow/serviceaccount.yaml.
sed "s|AIRFLOW_CLIENT_ID|${AIRFLOW_CLIENT_ID}|g" \
  kubernetes/airflow/serviceaccount.yaml | kubectl apply -f -

# ── 2. Airflow image ─────────────────────────────────────────────────────────
# Two build paths. Local Docker is tried first, which is the opposite of the
# obvious order, for a specific reason:
#
#   local buildx  deterministic and fails immediately when something is wrong.
#                 Must be told to target linux/amd64 — AKS nodes are x86, and an
#                 arm64 image built on an Apple Silicon laptop pulls fine and
#                 then crash-loops with "exec format error".
#
#   ACR Tasks     needs no Docker daemon and picks the architecture itself, but
#                 it *queues* the build server-side. When the subscription does
#                 not permit Tasks — Free Trial returns
#                 TasksOperationsNotAllowed — the rejection arrives after the
#                 context upload and a polling wait, so it reads as a hang
#                 rather than an error. Second, so its slow failure is never on
#                 the critical path.
#
# Both use the repository root as context so the image can COPY dags/. The
# .dockerignore at the root is load-bearing: without it the context is ~2.9 GB
# of Terraform provider binaries.
echo
echo "==> Building the Airflow image"
az acr login --name "$ACR_NAME" >/dev/null

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "    building locally for linux/amd64"
  docker buildx build \
    --platform linux/amd64 \
    --file docker/airflow/Dockerfile \
    --tag "${ACR_LOGIN_SERVER}/airflow:${AIRFLOW_IMAGE_TAG}" \
    --push \
    .
elif az acr build \
       --registry "$ACR_NAME" \
       --image "airflow:${AIRFLOW_IMAGE_TAG}" \
       --file docker/airflow/Dockerfile \
       . ; then
  echo "    built with ACR Tasks"
else
  echo "ERROR: no local Docker daemon, and ACR Tasks is unavailable on this subscription."
  echo "Start Docker Desktop, or run this from a machine or runner that has one."
  exit 1
fi

# Pin by digest, never by tag. A tag is a moving pointer; the digest is what
# actually ran, and it is what makes a rollback exact.
IMAGE_DIGEST=$(az acr repository show \
  --name "$ACR_NAME" \
  --image "airflow:${AIRFLOW_IMAGE_TAG}" \
  --query digest -o tsv)
echo "    digest: $IMAGE_DIGEST"

# ── 3. Secrets ───────────────────────────────────────────────────────────────
# Generated, never committed. Re-running the script does not rotate them —
# `--dry-run=client | kubectl apply` would overwrite the password while Postgres
# keeps the old one, so existing secrets are left alone.
echo
echo "==> Secrets"
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
  echo "    created grafana-admin"
else
  echo "    grafana-admin exists, leaving it alone"
fi

if ! kubectl get secret airflow-postgres -n airflow >/dev/null 2>&1; then
  PG_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
  kubectl create secret generic airflow-postgres -n airflow \
    --from-literal=postgres-password="$PG_PASSWORD" \
    --from-literal=password="$PG_PASSWORD"
  # Airflow reads a single connection string rather than the parts.
  kubectl create secret generic airflow-metadata -n airflow \
    --from-literal=connection="postgresql://airflow:${PG_PASSWORD}@airflow-postgresql.airflow.svc.cluster.local:5432/airflow"
  echo "    created airflow-postgres and airflow-metadata"
else
  echo "    airflow secrets exist, leaving them alone"
fi

# ── 3b. Metadata database ────────────────────────────────────────────────────
# Applied before the chart so the migration job has something to migrate into.
echo
echo "==> Airflow metadata database"
kubectl apply -f kubernetes/airflow/postgres.yaml
kubectl rollout status statefulset/airflow-postgresql -n airflow --timeout=5m

# ── 4. Monitoring ────────────────────────────────────────────────────────────
# Installed before Airflow so the ServiceMonitor CRDs exist when the Airflow
# chart renders. Without them the chart's ServiceMonitor is silently dropped and
# Airflow metrics never appear.
echo
echo "==> kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "$KPS_CHART_VERSION" \
  --values kubernetes/monitoring/values-sandbox.yaml \
  --wait --timeout 15m

# ── 5. Airflow ───────────────────────────────────────────────────────────────
echo
echo "==> Airflow"
helm repo add apache-airflow https://airflow.apache.org >/dev/null 2>&1 || true
helm repo update apache-airflow >/dev/null

VALUES_RENDERED=$(mktemp)
trap 'rm -f "$VALUES_RENDERED"' EXIT

sed \
  -e "s|ACR_LOGIN_SERVER|${ACR_LOGIN_SERVER}|g" \
  -e "s|IMAGE_DIGEST|${IMAGE_DIGEST}|g" \
  -e "s|AIRFLOW_CLIENT_ID|${AIRFLOW_CLIENT_ID}|g" \
  kubernetes/airflow/values-sandbox.yaml > "$VALUES_RENDERED"

helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --version "$AIRFLOW_CHART_VERSION" \
  --values "$VALUES_RENDERED" \
  --wait --timeout 20m

# ── 6. What to do next ───────────────────────────────────────────────────────
cat <<EOF

Deployed.

  Airflow UI    kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
                http://localhost:8080

  Grafana       kubectl port-forward -n monitoring svc/kps-grafana 3000:80
                http://localhost:3000
                user     admin
                password kubectl get secret grafana-admin -n monitoring \\
                           -o jsonpath='{.data.admin-password}' | base64 -d

Neither is exposed publicly: both services are ClusterIP, reached over
port-forward. A LoadBalancer would put the Airflow UI on the internet behind
nothing but a password.

  make cost ENV=$ENVIRONMENT    what this is costing, attributed by tag
  make stop ENV=$ENVIRONMENT    park the cluster, keep all state
EOF

#!/usr/bin/env bash
# =============================================================================
# Open every platform UI at once
# =============================================================================
# Nothing in this cluster is exposed publicly — no ingress controller, no
# LoadBalancer, no DNS record. Every service is ClusterIP, so the only way in is
# a port-forward through the Kubernetes API, which means an Entra token and
# membership of yoda-platform-admins are checked before a packet reaches a pod.
#
# That is a stronger control than any of these UIs applies for itself. Airflow's
# webserver has no local account at all here; reaching the forward IS the
# authorisation. See docs/ACCESS.md for when that stops being the right trade.
#
#   make ui        # or: ./scripts/bash/port-forward.sh
#
# Ctrl-C stops every forward.
# =============================================================================
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is not installed."; exit 1; }

if ! kubectl get ns airflow >/dev/null 2>&1; then
  cat <<'EOF'
ERROR: cannot reach the cluster, or the airflow namespace is missing.

  make kubeconfig ENV=sandbox

If that returns Forbidden, you are not in the admin group — the cluster has no
local admin account, so group membership is the only way in:

  GID=$(az ad group show --group yoda-platform-admins --query id -o tsv)
  az ad group member add --group "$GID" \
    --member-id "$(az ad signed-in-user show --query id -o tsv)"
  make kubeconfig ENV=sandbox
EOF
  exit 1
fi

PIDS=()
cleanup() {
  echo
  echo "Stopping port-forwards..."
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  echo "Done."
}
trap cleanup EXIT INT TERM

forward() {
  local ns="$1" svc="$2" local_port="$3" remote_port="$4"
  kubectl port-forward -n "$ns" "svc/$svc" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  PIDS+=($!)
}

forward airflow    airflow-webserver 8080 8080
forward monitoring kps-grafana       3000 80
forward monitoring kps-prometheus    9090 9090

# Give the forwards a moment before claiming they are up, so a failed bind is
# visible here rather than as a confusing connection refused in the browser.
sleep 3

GRAFANA_PW=$(kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "<not found>")
AIRFLOW_PW=$(kubectl get secret airflow-admin -n airflow \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<not found — see docs/ACCESS.md>")

cat <<EOF

  Airflow      http://localhost:8080
               user     admin
               password ${AIRFLOW_PW}
               the logistics_medallion DAG ships paused, deliberately

  Grafana      http://localhost:3000
               user     admin
               password ${GRAFANA_PW}
               dashboards are ConfigMaps; UI edits are lost on pod restart

  Prometheus   http://localhost:9090
               raw metrics and the target list, 7-day retention

  Databricks   https://adb-7405618211288916.16.azuredatabricks.net   (central)
               https://adb-7405609026613510.10.azuredatabricks.net   (logistics)
               public endpoints, Entra SSO — no forward needed

Ctrl-C to stop.

EOF

wait

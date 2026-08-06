# Accessing the platform

How to reach every UI and API, and why none of them is on the internet.

---

## The short version

**There is no ingress controller, no public load balancer and no DNS record for
any in-cluster service.** Airflow, Grafana and Prometheus are all `ClusterIP`
and reached through `kubectl port-forward`. Databricks and the Azure portal are
public endpoints protected by Entra sign-in.

That is a deliberate position, not an unfinished one:

| | Ingress + LoadBalancer | **port-forward** |
|---|---|---|
| Exposure | A public IP answering to the world | None |
| Authentication | Whatever the app does — Airflow's own password | Entra + Kubernetes RBAC, before a packet reaches the pod |
| Cost | Public IP, and an ingress controller to run | Zero |
| Audit | Ingress logs | AKS audit log — every session attributable |

An Airflow webserver on a public IP is protected by one application password.
Behind `port-forward` it is protected by an Entra token, membership of
`yoda-platform-admins`, and Kubernetes RBAC — all evaluated before a packet
reaches the pod. On a platform whose whole design position is that no credential
is stored anywhere, putting a password-protected UI on the internet would be the
weakest link in it.

The trade is that access needs a terminal and cluster credentials. For a
platform whose UI consumers are the team operating it, that is the right trade.
[§6](#6-when-to-add-an-ingress) covers when it stops being.

---

## 1. One-time setup

```bash
az login                                    # Entra sign-in
make kubeconfig ENV=sandbox                 # cluster credentials
kubectl get nodes                           # should list one Ready node
```

If `kubectl` returns **Forbidden**, you are not in the admin group. The cluster
has `local_account_disabled = true` — there is no admin kubeconfig, and group
membership is the only path in:

```bash
GID=$(az ad group show --group yoda-platform-admins --query id -o tsv)
az ad group member add --group "$GID" --member-id "$(az ad signed-in-user show --query id -o tsv)"
make kubeconfig ENV=sandbox                 # re-fetch; the old token lacks the claim
```

Membership can take a few minutes to appear in a fresh token.

---

## 2. In-cluster services

Open all three at once:

```bash
make ui
```

That runs `scripts/bash/port-forward.sh`, which starts every forward, prints the
URLs and the Grafana password, and cleans up the background processes on
`Ctrl-C`. Individually:

### Airflow

```bash
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
```

→ **http://localhost:8080**

```
user      admin
password  kubectl get secret airflow-admin -n airflow \
            -o jsonpath='{.data.password}' | base64 -d
```

Generated at deploy time and stored only as a Kubernetes secret, the same
pattern as Grafana.

> **Why there is a password at all.** The chart's `defaultUser` is disabled,
> and disabling it removes the *account* without disabling *authentication* —
> the webserver still runs `AUTH_TYPE = AUTH_DB` and still demands a login. The
> first version of this platform shipped that way and produced a login page no
> credential could satisfy. The alternative, `AUTH_ROLE_PUBLIC = Admin`, would
> make the UI genuinely passwordless and is defensible behind a port-forward —
> but it becomes an open admin console the moment anyone puts an ingress in
> front, which is too sharp an edge to leave lying around.

What to look at: the `logistics_medallion` DAG, its task graph, and task logs.
The DAG ships **paused** — that is deliberate. Unpausing a DAG whose
`start_date` is in the past would trigger a run immediately, and on a
spending-limited subscription an accidental backfill is expensive. Unpause it
only when you intend it to run.

### Grafana

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

→ **http://localhost:3000**

```
user      admin
password  kubectl get secret grafana-admin -n monitoring \
            -o jsonpath='{.data.admin-password}' | base64 -d
```

Generated at deploy time, never committed. Dashboards are ConfigMaps loaded by
the sidecar — **anything edited in the UI is lost on pod restart**, deliberately,
so the repository stays the source.

### Prometheus

```bash
kubectl port-forward -n monitoring svc/kps-prometheus 9090:9090
```

→ **http://localhost:9090**

Raw metrics and the target list. Useful when a Grafana panel is empty and you
need to know whether the metric is missing or the query is wrong. Retention is
7 days.

---

## 3. Databricks

Public endpoints, Entra SSO, no port-forward. The workspace UI is reachable
because `public_network_access_enabled = true` in sandbox — production sets it
false and puts a private endpoint in front, at which point these need the VNet.

| Workspace | URL |
|---|---|
| Central (platform) | https://adb-7405618211288916.16.azuredatabricks.net |
| Logistics (domain) | https://adb-7405609026613510.10.azuredatabricks.net |

**Account console:** https://accounts.azuredatabricks.net

Sign in with a **native Entra member** account. An MSA guest identity
(`...#EXT#@...`) cannot resolve the account and the console will loop on the
email prompt — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#2-databricks-and-unity-catalog).

Inside a workspace: **Catalog** for Unity Catalog, **Compute → Policies** for
the cluster policies, **SQL Warehouses** for the serverless endpoints. The
warehouses are stopped and cost nothing; running a query starts one and it
auto-stops after 10 minutes.

**API access needs no PAT** — an Azure CLI token works:

```bash
TOKEN=$(az account get-access-token \
  --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)
curl -H "Authorization: Bearer $TOKEN" \
  "https://adb-7405618211288916.16.azuredatabricks.net/api/2.1/unity-catalog/catalogs"
```

`2ff814a6-…` is Databricks' first-party Entra application. That one substitution
is what removes personal access tokens from this platform entirely.

---

## 4. Azure

```bash
az login
az account set --subscription 6b1fb7ca-983c-4b78-b682-a770113749e6
```

| What | Where |
|---|---|
| All resources | Portal → Resource groups → `rg-yoda-sandbox-*` |
| Audit and diagnostics | Log Analytics workspace `log-yoda-sandbox` → Logs |
| Alerts | Monitor → Alerts, scoped to `rg-yoda-sandbox-observability` |
| Cost | Cost Management → Cost analysis, or `make cost ENV=sandbox` |
| Policy compliance | Policy → Compliance → `yoda-sandbox-baseline` |

The data lake is **not** browsable from the portal by default: the storage
firewall denies by default and allows only the operator IP recorded at
`make tfvars` time. If your address has changed, regenerate and apply:

```bash
make tfvars ENV=sandbox && make plan ENV=sandbox && make apply ENV=sandbox
```

Useful queries:

```kusto
DatabricksUnityCatalog | where TimeGenerated > ago(24h) | take 50   // who read what
StorageBlobLogs        | where TimeGenerated > ago(24h) | take 50   // lake access
Usage | where IsBillable | summarize GB=sum(Quantity)/1000 by DataType  // ingestion vs the 1 GB cap
```

---

## 5. Operating from the repository

Most day-to-day questions have a target rather than a UI:

```bash
make cost   ENV=sandbox     # month-to-date by tag; untagged spend first
make drift  ENV=sandbox     # Unity Catalog grants added outside Terraform
make quota  ENV=sandbox     # vCPU headroom
make scim-check             # can Unity Catalog resolve the Entra groups?
make plan   ENV=sandbox     # infrastructure drift
make stop / make start      # park the cluster, ~60% off the bill
```

---

## 6. When to add an ingress {#6-when-to-add-an-ingress}

Port-forward stops being right the moment **someone outside the platform team
needs a dashboard**. At that point the requirement is real and the answer is
not a public IP:

1. **Ingress controller** (`ingress-nginx` or AGIC) with a private IP on
   `snet-platform` — internal only.
2. **Entra authentication in front** — OAuth2 Proxy, or Application Gateway with
   Entra pre-auth. Not the application's own password.
3. **Private DNS** for the internal name.
4. **Reachability** — Bastion, VPN or ExpressRoute. This is the real cost, and
   the reason it has not been done: there is currently no private path into the
   VNet at all.

Doing steps 1–3 without 4 achieves nothing; doing 1 and 4 without 2 is worse
than port-forward. Cost is roughly €25/month for an internal Application
Gateway, plus whatever the private path costs.

Until then, `make ui` is the interface.

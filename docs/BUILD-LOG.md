# Build log

A record of how this platform was built: what was decided, what broke, and what
was changed as a result. Kept because the interesting engineering is rarely in
the final state — it is in the problems the final state had to survive.

**Date:** 2026-08-05 · **Region:** Sweden Central · **Subscription:** Free Trial,
spending limit on, 4 vCPU regional quota

---

## 1. Starting position

The subscription already carried a previous lab (`rebtel-lab-sandbox`) built on
the same conventions this repository follows: Terraform modules, remote state,
ADRs with cost and revisit triggers, CI parity between GitHub Actions and Azure
DevOps.

Reconnaissance found three things that shaped everything after:

| Finding | Consequence |
|---|---|
| **4 / 4 vCPU used** in Sweden Central | Nothing new could be deployed until the old lab was removed |
| **Free Trial, spending limit on** | Exceeding the credit disables services — cost control is an availability control |
| Global Administrator + Groups Administrator held | Unity Catalog metastore and Entra group creation were possible |

---

## 2. Teardown

`terraform destroy` against the previous lab's own state, so no orphaned state
was left behind: **60 resources destroyed**, all 4 vCPU released.

Two discoveries during cleanup:

- **`apidemotest` was API Management, Developer tier** — roughly EUR 45/month
  for a service nothing referenced.
- **A stale state file in East US managed four live subscription-level policy
  definitions** plus an initiative. They were `DoNotEnforce`, so harmless, but
  unowned. Removed deliberately rather than orphaned by deleting the resource
  group around them.

Combined with the Managed Grafana instance, teardown removed roughly
**EUR 90/month of idle spend**. Finding unowned resources is the highest-yield
FinOps activity there is, which is why `make cost` reports untagged spend first.

---

## 3. Decisions taken, and why

The four that shaped the architecture:

| Decision | Alternative rejected | Reason |
|---|---|---|
| **Serverless-first Databricks** | Classic VNet-injected compute | A classic cluster needs a 4-vCPU node — the entire quota — leaving nothing for AKS. Serverless runs in Databricks' subscription and consumes none |
| **Workspace per domain** | One workspace, catalogs for isolation | The workspace, not the catalog, is the boundary for cluster policies, admins and the DBU line. Sharing one makes "which domain spent this" unanswerable |
| **Grafana OSS in-cluster** | Azure Managed Grafana | ~EUR 45/month against a EUR 50 budget — the entire budget for one dashboard server |
| **Two Terraform roots** | Single root with `-target` | The `databricks` provider `host` is a workspace URL that does not exist until the workspace is applied, and a provider cannot depend on a resource in its own apply |

Full reasoning, cost and revisit triggers: [DECISIONS.md](DECISIONS.md).

---

## 4. What broke, and what changed as a result

Every item below was found by applying against live Azure. None would have been
caught by `terraform validate` or by a plan — which is the argument for
[ADR-002](DECISIONS.md#adr-002), and the reason `sandbox` is genuinely applied
rather than illustrative.

| # | Failure | Root cause | Fix |
|---|---|---|---|
| 1 | `count` cannot depend on an unknown value | Conditioned on `log_analytics_workspace_id != ""`, produced by another module | Explicit plan-time booleans (`enable_diagnostics`, `enable_acr_pull`, `enable_key_vault_grant`) |
| 2 | AKS create rejected version 1.31 | 1.31 has aged into `AKSLongTermSupport`; the error names the version, not the support plan | Pinned 1.34 (`KubernetesOfficial`); documented the `az aks get-versions` query in the variable |
| 3 | Storage firewall rejected the operator range expressed as `/32` | Storage accepts a bare address or `/0`–`/30`, never `/32` — uniquely among Azure firewalls | Normalise in a local; callers still write CIDR |
| 4 | Lifecycle policy rejected | Last-access tiering needs `last_access_time_enabled` first | Enabled it — tiering bronze on creation date would demote partitions still being queried |
| 5 | Alert rule rejected twice | `Response` is a string not dynamic; the column is `Identity`, not `UserIdentity` | `parse_json` and the correct column |
| 6 | **External locations overlapped** | Unity Catalog external locations are metastore-scoped and may not overlap; both domains registered the container root | Each domain owns `abfss://{layer}@lake/{domain}/`. Had it succeeded, both domains would have held the whole layer — the isolation the workspace split exists to create |
| 7 | Storage credential update loop | Databricks spells `isolation_mode` two ways: `ISOLATION_MODE_*` on credentials and locations, bare `ISOLATED` on catalogs | Mapped in a local; added `force_update` |
| 8 | ACR Tasks rejected | `TasksOperationsNotAllowed` on Free Trial — and it *queues* before failing, so it reads as a hang | Local `buildx --platform linux/amd64` first, ACR Tasks second |
| 9 | Build appeared to hang for ten minutes | Context was the repo root: **2.9 GB** of Terraform provider binaries | Added `.dockerignore`; context is now under a megabyte |
| 10 | Airflow chart template error | Values under `config` are compared as strings; unquoted YAML booleans render as `false` | Quoted them |
| 11 | Every Airflow pod unschedulable | The chart has no global `serviceAccount` block, so `create: true` did nothing | Own the ServiceAccount explicitly — it is the federated-credential subject and belongs in the repository |
| 12 | Postgres `ErrImagePull` | Bitnami withdrew the tag the subchart pins | Replaced with a 40-line StatefulSet on the official image, `restricted`-compliant |
| 13 | statsd rejected by Pod Security | Chart container sets neither `runAsNonRoot` nor `seccompProfile` | Per-component `securityContexts` rather than relaxing the namespace |
| 14 | git-sync could not reach the repo | Repository not yet pushed; the DAGs were not on the remote | DAGs baked into the image — immutable, rollback-exact, no runtime GitHub dependency |
| 15 | **Scheduler ran a stale image** | Pinned by tag with `IfNotPresent`; the node had a cached `:2.10.5` without the DAG | Pin by digest. This is precisely what the Dockerfile comment warned about, and it happened anyway |
| 16 | Rolling update never converged | A 2 vCPU node cannot hold old and new pods at once | `strategy: Recreate`, `updateStrategy: OnDelete` — the same trade as `max_surge = "10%"` on the node pool |
| 17 | Trivy CRITICAL on the API server | Trivy cannot see a value arriving through a variable | Made `api_server_authorized_ip_ranges` **required** with a non-empty validation — a stronger guarantee than the one Trivy wanted, failing at plan time |
| 18 | tflint found three dead declarations | Including `flow_logs_workspace_id`, a variable promising a control never built | Removed; NSG flow logs recorded as a gap rather than implied by an unused input |

---

## 5. Final verification

```
terraform fmt -check -recursive      PASS
terraform validate (14 roots)        PASS
tflint --recursive                   clean
trivy config (CRITICAL gate)         PASS — 0 HIGH/CRITICAL remaining
cluster policy contract              PASS
Airflow DAG import check             PASS
terraform plan (sandbox)             No changes — infrastructure matches configuration
```

**Deployed and running:** 40 Azure resources across 6 resource groups; 2
Databricks Premium workspaces with Unity Catalog, 2 catalogs, 4 cluster
policies, 2 serverless SQL warehouses; AKS 1.34 with 11 pods (Airflow scheduler,
webserver, triggerer, statsd, Postgres; Prometheus, Grafana, kube-state-metrics,
node-exporters, operator); `logistics_medallion` registered in the scheduler.

`uc_drift.py` runs against the live workspaces and reports one finding — the
catalogs are owned by the creating user because `enable_grants = false` pending
SCIM. That is the documented state, and the tool correctly refuses to call it
clean.

---

## 6. Known gaps

Recorded in full in [COVERAGE.md](COVERAGE.md). The ones that matter most:

| Gap | Why | Closing it |
|---|---|---|
| Unity Catalog grants not applied | SCIM has not synchronised Entra groups into the Databricks account | [RUNBOOKS.md](RUNBOOKS.md#scim-provisioning), then `enable_grants = true` |
| Private endpoints off in sandbox | ~EUR 7 per endpoint per month against a EUR 50 budget | One tfvar; `prod` already sets it |
| `prod` never applied | No subscription with 24 vCPU or the budget | An apply and a teardown |
| NSG flow logs not built | Needs a storage account and Network Watcher wiring | Required before `enable_strict_egress` is trustworthy |
| MLOps designed only | Steps 1–4 in [MLOPS.md](MLOPS.md) cost job DBU only | The obvious next increment |

---

## 7. What would be done differently

- **Check provider enum spellings before writing the module.** Items 5 and 7
  cost two apply cycles between them and were both documentation lookups.
- **Write `.dockerignore` at the same commit as the Dockerfile.** Item 9 cost
  more wall-clock time than any genuine engineering problem in this build.
- **Pin by digest from the first deployment, not after being burned.** Item 15
  is the clearest lesson here: the comment warning against tag-pinning was
  already in the file when the tag-pinned deployment shipped. Writing the
  principle down is not the same as enforcing it — which is why the cluster
  policy contract is asserted by a CI check rather than by a comment.

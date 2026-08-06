# Technology stack

Every Azure service and tool in this platform: what it is, why it is here, and
what was rejected in its place.

The organising question throughout is **what does this earn its place doing that
the alternative could not** — a stack list without that is an inventory, not a
design.

---

## 1. At a glance

| Layer | Service / tool | Purpose in one line |
|---|---|---|
| Storage | **Azure Data Lake Storage Gen2** | The lake. Hierarchical namespace makes Delta commits atomic |
| Table format | **Delta Lake** | ACID transactions, time travel, `DEEP CLONE` for DR |
| Processing | **Azure Databricks** (Premium) | Runs every transformation; serverless so it costs no quota |
| Governance | **Unity Catalog** | The single point where data access is authorised and logged |
| Identity | **Microsoft Entra ID** | Every principal, human and workload. No other identity provider |
| Orchestration | **Apache Airflow** | Schedules work, handles dependencies and retries |
| Orchestration host | **Azure Kubernetes Service** | Runs Airflow and the monitoring stack on 2 vCPU |
| Networking | **Virtual Network, NSG, Private Link** | Segmentation by trust level, default-deny |
| Secrets | **Azure Key Vault** | The small set of credentials that cannot be federated |
| Images | **Azure Container Registry** | The Airflow image, pinned by digest |
| Telemetry (Azure) | **Log Analytics** | Azure resource logs — audit, diagnostics |
| Telemetry (workload) | **Prometheus + Grafana OSS** | What the workloads emit |
| Guardrails | **Azure Policy** | Blocks misconfiguration at creation |
| Cost | **Cost Management budgets** | Forecast and actual alerting |
| IaC | **Terraform** | All Azure infrastructure |
| In-cluster | **Helm** | What runs inside Kubernetes |
| CI/CD | **GitHub Actions + Azure DevOps** | Same gates, two platforms |
| Scanning | **Trivy, tflint, checkov-equivalent gates** | IaC security and lint |

---

## 2. Storage and table format

### Azure Data Lake Storage Gen2

**Why not plain Blob Storage.** The hierarchical namespace is not a convenience
feature here — it is a correctness requirement. Delta Lake's commit protocol
depends on an **atomic rename**. On flat blob storage that operation is
emulated, is not atomic, and concurrent writers can corrupt a table. Directory
ACLs also do not exist without it.

**Why one account, not one per layer.** An account per medallion layer buys
independent firewall rules and quota, and costs a Unity Catalog external
location and a private endpoint pair each. The container boundary is sufficient
because the access decision is made by Unity Catalog, not by storage RBAC — no
human or job holds a data-plane role on this account.

**The setting that matters most:** `shared_access_key_enabled = false`. It
removes the storage key rather than protecting it, so the credential that most
commonly leaks does not exist.

### Delta Lake

Chosen over Parquet-plus-convention and over Iceberg.

| | Parquet + convention | Iceberg | **Delta** |
|---|---|---|---|
| ACID on concurrent writes | no | yes | yes |
| Time travel / restore | no | yes | yes |
| Cross-region copy | manual | manual | `DEEP CLONE`, incremental |
| Databricks-native | — | partial | full |

`DEEP CLONE` being incremental and re-runnable is what makes both the DR design
and the YODA regional migration affordable — the final sync before cutover
copies only what changed since the last run.

---

## 3. Processing

### Azure Databricks, Premium tier

**Premium is not an upsell.** Unity Catalog, cluster policies, table ACLs, audit
log delivery and SCIM all require it, and every one is load-bearing here.

**Why serverless compute.** The subscription has a 4 vCPU regional quota. One
classic VNet-injected cluster needs a 4-vCPU node — the entire allowance —
leaving nothing for the orchestration layer. Serverless runs in Databricks'
own subscription and consumes none of it. The classic path is fully built in
Terraform and gated behind one variable.

**Why a workspace per domain.** The workspace, not the catalog, is the boundary
for cluster policies, workspace administrators and the DBU line on the bill.
Domains sharing one share all three, and "which domain spent this" stops having
an answer.

**Rejected alternatives:**

| Option | Why not |
|---|---|
| Azure Synapse Analytics | Weaker Delta and Unity Catalog story; Microsoft's own direction is Fabric |
| Microsoft Fabric | Capacity-based pricing does not fit a bursty, quota-constrained platform; less mature governance |
| HDInsight | Effectively legacy |
| Spark on AKS | Would consume the quota Databricks avoids, and rebuilds what Databricks already operates |

### Unity Catalog

The single most consequential choice in the platform. It is the **only** place
data access is authorised, which is what makes "who read this table" a question
with an answer.

The alternative — Unity Catalog grants *plus* storage RBAC — was rejected
because two authorisation systems over the same data means two places to review
and two places to get it wrong, and storage RBAC silently wins: a principal with
`Storage Blob Data Reader` reads the Parquet directly and bypasses every column
mask and row filter that makes `gold` safe to publish.

---

## 4. Orchestration

### Apache Airflow

**Why not Databricks Workflows**, which would be simpler:

| | Databricks Workflows | **Airflow** |
|---|---|---|
| Databricks jobs | native | via provider |
| Non-Databricks steps | limited | any operator |
| Cross-system dependencies | weak | the core use case |
| Portability | Databricks-bound | portable |
| Operational burden | none | a cluster to run |

The deciding factor is that a real platform orchestrates more than Spark — file
arrival, API calls, downstream notification, cross-domain dependencies. Airflow
is also what the engagement specifies at expert level.

**Why self-hosted on AKS rather than ADF Managed Airflow.** Managed Airflow
removes the operational surface and, with it, the control: custom images,
executor choice, and the Kubernetes skill the platform is judged on. Self-hosting
demonstrates both.

**Deferrable operators are what make it fit.** A non-deferrable
`DatabricksSubmitRunOperator` holds a worker pod for the entire Databricks run.
On one 2 vCPU node that is roughly two concurrent tasks, so two four-hour jobs
would block the scheduler for four hours doing nothing but waiting. Deferred
tasks release their pod and resume on the triggerer.

### Azure Kubernetes Service

Runs the orchestration and observability layer — **it does not process data**.
That separation is why 2 vCPU is enough.

| Choice | Reason |
|---|---|
| Free tier control plane | No SLA needed on a lab; Standard is ~€65/month |
| CNI Overlay + Cilium | Pod IPs from an overlay, so pod density never exhausts the subnet; eBPF NetworkPolicy with no sidecar |
| Workload identity + OIDC | Pods federate to Entra — no mounted secrets |
| `local_account_disabled` | No client certificate that outlives an employee |
| Pod Security `restricted` | Blocks privileged pods at admission, before a NetworkPolicy has to contain them |

**Rejected:** Azure Container Apps (no Kubernetes demonstration, weaker
scheduling control) and Container Instances (no orchestration at all).

---

## 5. Networking

| Component | Purpose |
|---|---|
| Virtual Network `/16` | One address plan; Databricks gets a contiguous `/20` |
| Delegated subnets | Databricks VNet injection — a host/container pair per workspace |
| NSGs per trust level | Default-deny inbound everywhere; egress by **service tag** so rules survive Azure re-IPing |
| Service endpoints | Storage and Key Vault over the Azure backbone at no cost |
| Private Link + private DNS | Production: PaaS reachable only on a VNet address |
| NAT Gateway | Deterministic egress for classic Databricks compute |
| Standard Load Balancer | AKS outbound — which is why AKS needs no NAT |

**Secure Cluster Connectivity** means no cluster node has a public IP and the
control plane never initiates inbound — the worker dials out and holds the
tunnel. That is why the Databricks NSG's deny-all-inbound is unconditional.

Full treatment against Confidentiality, Integrity and Availability:
[NETWORK-CIA.md](NETWORK-CIA.md).

---

## 6. Observability

**Two stores, split by signal origin — not by preference.**

| Store | Holds | Why it cannot be the other |
|---|---|---|
| **Prometheus + Grafana OSS** (in-cluster) | What workloads emit — DAG duration, pod and node metrics | Free, and the signals are already in the cluster |
| **Log Analytics** | What Azure emits *about* resources — Databricks audit, storage access, AKS control plane | Prometheus cannot see any of it |

Azure Managed Grafana was replaced by Grafana OSS to save ~€45/month against a
~€50 budget — the entire budget for one dashboard server. What is given up is
SSO, managed availability and zone redundancy; all acceptable while the
consumers are the team operating it, and the stated trigger to revisit is the
moment anyone outside that team depends on a dashboard.

Databricks diagnostic categories are **enumerated, not `allLogs`** — Databricks
exposes around twenty and most are high-volume noise. On a 1 GB/day cap, `all`
would exhaust the quota before lunch.

---

## 7. Governance and cost

| Tool | Role |
|---|---|
| **Azure Policy** | Blocks misconfiguration at creation: TLS floor, no public blob, Databricks must be Premium + SCC, allowed regions |
| **Databricks cluster policies** | Where FinOps actually happens — everything expensive about Databricks is a cluster setting |
| **Cost Management budgets** | Forecast alerts before actual, because actual at 80% may leave two days in the month |

Cluster policy tags are `fixed`, not `allowlist`: a user who can edit the
`domain` tag can move spend onto another team's cost centre, usually by accident
when cloning someone else's cluster.

**A lesson from operating it:** policy compliance is not cost attribution. Azure
Policy reported the platform broadly compliant while 99 percent of spend sat in
AKS-managed resources it does not evaluate. See [FINOPS.md](FINOPS.md).

---

## 8. Tooling

### Terraform, not Bicep or ARM

| | Bicep | **Terraform** |
|---|---|---|
| Azure resources | first-party, fastest to new features | provider lag of days to weeks |
| Databricks workspace objects | **cannot** | first-class provider |
| Entra ID objects | limited | `azuread` provider |
| Multi-cloud | no | yes |

The deciding factor is Databricks: catalogs, grants, cluster policies and SQL
warehouses are Databricks API objects, not ARM resources. Bicep cannot express
them, so a Bicep platform would need a second tool for the half of the platform
that matters most.

### Helm for in-cluster, Terraform for Azure

The boundary is deliberate. A Helm release managed through Terraform's `helm`
provider couples a chart upgrade to a Terraform state lock — a failed chart
render then blocks every unrelated infrastructure change until someone unlocks
it.

### Python and Bash

Python for anything that parses structured output — the FinOps report, the
Unity Catalog drift detector, the policy contract and DAG validators. Bash for
process orchestration where the work is invoking other tools: quota preflight,
metastore check, deployment.

The line is: **if it parses JSON, it is Python.**

---

## 9. What is deliberately absent

| Not used | Why |
|---|---|
| Azure Data Factory | Airflow already orchestrates; ADF would be a second scheduler with a second set of credentials |
| Azure Synapse / Fabric | See §3 |
| Event Hubs / Stream Analytics | No streaming requirement yet. The `checkpoints` container exists for when there is |
| Azure Monitor Workspace (Prometheus) | In-cluster Prometheus is free and already has the signals |
| Service Bus | Nothing needs a message broker; Airflow handles dependencies |
| A second cloud | Deliberately Azure-only — [ADR-012](DECISIONS.md#adr-012) |
| Terraform Cloud | Azure Storage backend with Entra auth is sufficient and adds no vendor |

Adding a service that duplicates one already present is the most common way a
platform becomes expensive to operate, so each absence above is a decision
rather than an oversight.

---

## 10. Where each choice is argued

Every significant decision carries a cost and a revisit trigger in
[DECISIONS.md](DECISIONS.md). The ones this document summarises:

| ADR | Decision |
|---|---|
| [001](DECISIONS.md#adr-001) | Sweden Central as the home region |
| [003](DECISIONS.md#adr-003) | Serverless-first Databricks compute |
| [005](DECISIONS.md#adr-005) | Federation everywhere, no stored secrets |
| [006](DECISIONS.md#adr-006) | A workspace per data domain |
| [010](DECISIONS.md#adr-010) | In-cluster Postgres for Airflow metadata |
| [011](DECISIONS.md#adr-011) | Grafana OSS instead of Azure Managed Grafana |
| [012](DECISIONS.md#adr-012) | Unity Catalog as the only authorisation point |
| [014](DECISIONS.md#adr-014) | Deferrable operators for every external wait |

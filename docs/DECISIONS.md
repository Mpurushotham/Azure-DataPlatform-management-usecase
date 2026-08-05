# Architecture Decision Records

Each record states the decision, what it costs, what it buys, and what would
make us revisit it. The last part matters most: a decision without a trigger
for revisiting is a decision nobody can safely change later.

Costs are illustrative monthly figures for Sweden Central, used to make
trade-offs concrete. Validate against the Azure pricing calculator for your
actual region and reservation position before quoting them.

| ADR | Decision | Status |
|---|---|---|
| [001](#adr-001) | Sweden Central as the home region | Accepted |
| [002](#adr-002) | sandbox is applied, prod is code-complete | Accepted |
| [003](#adr-003) | Serverless-first Databricks compute | Accepted |
| [004](#adr-004) | No NAT gateway until classic compute exists | Accepted |
| [005](#adr-005) | Federation everywhere, no stored secrets | Accepted |
| [006](#adr-006) | A workspace per data domain | Accepted |
| [007](#adr-007) | The metastore is a precondition, not a resource | Accepted |
| [008](#adr-008) | Two Terraform roots for Databricks | Accepted |
| [009](#adr-009) | Alert on symptoms, not causes | Accepted |
| [010](#adr-010) | In-cluster Postgres for Airflow metadata | Accepted |
| [011](#adr-011) | Grafana OSS instead of Azure Managed Grafana | Accepted |
| [012](#adr-012) | Unity Catalog is the only authorisation point | Accepted |
| [013](#adr-013) | GitHub Actions and Azure DevOps in parity | Accepted |
| [014](#adr-014) | Deferrable operators for every external wait | Accepted |

---

## ADR-001 — Sweden Central as the home region {#adr-001}

**Decision.** Sweden Central is the platform's primary region. West Europe stays
in the `allowed_locations` policy only for the duration of the YODA migration.

**Alternatives.**

| Option | Latency to Nordic users | Residency | Databricks features |
|---|---|---|---|
| West Europe (current) | ~30ms | EU, not Nordic | Full |
| **Sweden Central** | ~5ms | Sweden | Full |
| Sweden Central + West Europe active/active | ~5ms | Split | Full, doubled cost |

**Why.** Data residency is the binding reason, not latency. A Swedish logistics
operator's shipment data has a clear preference for staying in-country, and
Sweden Central's paired region is Sweden South — so the DR story stays inside
Sweden too. The latency improvement is real but secondary.

**Cost of the decision.** Sweden Central lists slightly higher than West Europe
for several SKUs, and lags it on preview-feature availability by roughly one
quarter. The migration itself is the larger cost — see
[MIGRATION-YODA.md](MIGRATION-YODA.md).

**Revisit if.** A required Azure or Databricks capability is unavailable in
Sweden Central for more than two quarters, or the business expands outside the
Nordics such that a second primary region is genuinely warranted.

---

## ADR-002 — sandbox is applied, prod is code-complete {#adr-002}

**Decision.** Two environments. `sandbox` is deployed against a real
subscription. `prod` is written, validated and linted in CI but never applied
here.

**Why.** A reference architecture nobody has applied hides its own mistakes.
Everything in `sandbox` has actually been created, which is how the AKS version
constraint, the storage firewall's rejection of `/32`, and the Unity Catalog log
schema were found — none of which a plan or a `validate` would have surfaced.

`prod` carries the settings a Free Trial subscription cannot fund: private
endpoints, customer-managed keys, zone-redundant storage, Defender plans,
Postgres Flexible Server. Keeping them in code rather than in prose means they
are reviewed, linted and scanned like everything else.

**Cost of the decision.** The prod path is unproven. Its first apply will find
problems, and the two environments can drift because only one is exercised.
`make validate` runs across both roots to limit that, but validation is not
application.

**Revisit if.** A subscription with real quota becomes available — at which
point prod should be applied at least once, even if it is torn down after.

---

## ADR-003 — Serverless-first Databricks compute {#adr-003}

**Decision.** SQL warehouses and jobs use Databricks serverless compute.
Classic VNet-injected compute is fully built in Terraform but not used.

**Alternatives.**

| Option | Subscription vCPU | Network posture | Idle cost |
|---|---|---|---|
| Classic, VNet-injected | 4 minimum per cluster | Traffic in our VNet, our NSGs | Node cost while running |
| **Serverless** | 0 | Runs in Databricks' network | Zero |
| Serverless + NCC private link | 0 | Private connectivity to our storage | Zero |

**Why.** The subscription has a 4 vCPU regional quota. One classic cluster
consumes all of it, leaving nothing for AKS — so the choice was between a data
platform with no orchestration layer, or serverless. Serverless also bills per
second with no idle charge, which suits a platform used in bursts.

**Cost of the decision.** Serverless compute runs outside our VNet, so NSG
egress rules and the NAT gateway's deterministic source address do not apply to
it. Reaching a private-endpoint-only storage account from serverless needs a
Network Connectivity Configuration, which is a different mechanism from the one
classic compute uses — so the private-networking story is not identical across
the two. DBU rates for serverless are also higher per unit than classic on
long-running workloads.

**Revisit if.** Quota increases enough to fund classic compute alongside AKS, or
a workload needs a runtime feature serverless does not support (custom init
scripts, specific ML runtimes, GPU). Turning it on is `enable_nat_gateway` plus
a cluster definition — the subnets, NSG rules and policies already exist.

---

## ADR-004 — No NAT gateway until classic compute exists {#adr-004}

**Decision.** `enable_nat_gateway = false` in sandbox. The gateway, its
zone-redundant public IP and the subnet associations are all in code.

**Why.** Azure retired default outbound access for VNets created after
30 September 2025, so a classic Databricks cluster genuinely cannot reach its
control plane without an explicit egress path. But sandbox runs serverless
compute, which egresses from Databricks' own network — so the gateway would sit
idle at roughly EUR 32/month plus data processing.

AKS is unaffected either way: its Standard Load Balancer provides outbound
rules, which is why the platform subnet has no NAT association even in prod.

**Cost of the decision.** The moment someone starts a classic cluster it will
fail to launch, and the error will be a timeout against the control plane rather
than anything mentioning egress. `scripts/bash/check-quota.sh` and this ADR are
the mitigation; a better one would be a policy that denies classic cluster
creation while the gateway is off.

**Revisit if.** Classic compute is enabled, or a partner requires a
deterministic source address for an allowlist.

---

## ADR-005 — Federation everywhere, no stored secrets {#adr-005}

**Decision.** No client secret, storage key, SAS token or Databricks PAT exists
anywhere in this platform. CI federates through OIDC; pods federate through AKS
workload identity; Unity Catalog reaches storage through an Access Connector
managed identity.

**Why.** The most common way a data platform is compromised is a long-lived
credential in a CI variable group or a notebook. `shared_access_key_enabled =
false` on the lake is the strongest single control here: it removes the
credential rather than protecting it, so there is nothing to leak, rotate or
find in a git history.

The federation subject is scoped to one namespace and one ServiceAccount
(`system:serviceaccount:airflow:airflow`), so compromising the Grafana pod does
not yield Airflow's access to Databricks.

**Cost of the decision.** Bootstrapping is more involved than a secret: the CI
identity needs federated credentials per environment, and the GitHub subject
must match exactly or the exchange fails with an opaque error. Local development
depends on `az login` rather than a portable credential file.

**Revisit if.** A workload genuinely cannot federate — a third-party SaaS
connector, for instance. Those belong in Key Vault, read through the CSI driver,
never in a values file.

---

## ADR-006 — A workspace per data domain {#adr-006}

**Decision.** One Databricks workspace per domain, plus a central platform
workspace. One Unity Catalog catalog per workspace, one-to-one.

**Alternatives.**

| Option | Cost attribution | Policy isolation | Operational overhead |
|---|---|---|---|
| Single workspace, catalog per domain | Shared DBU line | Shared cluster policies | Lowest |
| **Workspace per domain** | Per-domain DBU | Per-domain policies | One module instance each |
| Subscription per domain | Per-domain bill | Total | Highest |

**Why.** A workspace — not a catalog — is the boundary for cluster policies,
workspace administrators, and the DBU line on the bill. Domains sharing a
workspace share all three, and "which domain spent this" stops having an answer.
The JD's language about a central platform and domain teams describes exactly
this shape.

**Cost of the decision.** Each workspace needs its own injected subnet pair,
which consumes address space and makes the network module's allocation
index-sensitive — the `databricks_workspaces` list is append-only, and
reordering it renumbers existing workspaces. Terraform cannot select a provider
from a `for_each` key, so each domain also needs an explicit provider alias and
module block (see [ADR-008](#adr-008)).

**Revisit if.** The number of domains grows past roughly eight, at which point
the `/20` Databricks block and the per-domain boilerplate both need rethinking —
probably toward a workspace per business unit rather than per domain.

---

## ADR-007 — The metastore is a precondition, not a resource {#adr-007}

**Decision.** Terraform does not create the Unity Catalog metastore. It is
checked by `scripts/bash/check-metastore.sh` and assumed to exist.

**Why.** Creating a metastore is an *account-level* operation against
`accounts.azuredatabricks.net`, requiring account-admin credentials that a
workspace-scoped provider does not hold. Azure Databricks also auto-provisions
one per region on first workspace creation, so a Terraform-managed metastore
would frequently conflict with one that already exists — and a metastore is
regional and shared, so the environment that happens to create it owns a
resource every other environment depends on.

**Cost of the decision.** A genuine manual step in an otherwise fully automated
platform, and one that is easy to miss because the resulting error does not
mention metastores. The check script exists specifically to convert that into a
clear message.

**Revisit if.** The Databricks provider gains reliable account-level metastore
management that tolerates a pre-existing auto-provisioned metastore, or the
organisation standardises on creating metastores through a separate
account-scoped pipeline — which is the right answer at PostNord scale.

---

## ADR-008 — Two Terraform roots for Databricks {#adr-008}

**Decision.** `envs/sandbox` creates Azure infrastructure including the
workspaces. `envs/sandbox-databricks` configures Unity Catalog and cluster
policies, reading the first root's outputs through a remote state data source.

**Alternatives.**

| Option | Works? | Cost |
|---|---|---|
| Single root | No | Provider `host` cannot depend on a resource in the same apply |
| Single root + `-target` | Yes | `-target` skips dependency checking and must be remembered every time |
| Provider host from a variable | Yes | Apply, copy a URL by hand, edit tfvars, apply again |
| **Two roots + remote state** | Yes | One extra state file and an ordering requirement in CI |

**Why.** Terraform must configure every provider before it builds the graph, so
a provider `host` cannot come from a resource created in that same apply. Of the
options that work, only the two-root split makes the dependency explicit and
machine-readable — CI runs them in order without anyone remembering a flag.

**Cost of the decision.** Two applies instead of one, a second state file, and
the ordering has to be encoded in the pipeline. Destroying is also ordered:
the Databricks root must be destroyed first.

**Revisit if.** Terraform gains deferred provider configuration, or the
workspace URL becomes predictable from inputs alone (it is derived from an
Azure-assigned workspace ID, so this is unlikely).

---

## ADR-009 — Alert on symptoms, not causes {#adr-009}

**Decision.** Alerts fire on conditions a user would notice. No alert fires on
CPU, memory, disk or node count.

**Why.** "Node memory above 80 percent" pages someone for a condition the
autoscaler is already handling. "Gold tables are stale" means a report is wrong
right now. The second is worth waking someone for; the first trains people to
ignore the channel, which is how the genuine page gets missed.

Every rule in `modules/observability/alerts.tf` states what is broken for a
user, what the person woken up should do, and why the threshold is that number.
A rule that cannot answer all three is not added.

**Cost of the decision.** Symptom alerts fire later than cause alerts — the
staleness alert triggers after the SLO is already breached, not before. Leading
indicators are a dashboard concern here, not an alerting one.

**Revisit if.** A recurring incident has a reliable leading indicator with a low
false-positive rate. That earns a cause-based alert, and the ADR should record
which incident justified it.

---

## ADR-010 — In-cluster Postgres for Airflow metadata {#adr-010}

**Decision.** Airflow's metadata database is a Postgres StatefulSet on an Azure
Disk PVC. Production uses Azure Database for PostgreSQL Flexible Server.

**Alternatives.**

| Option | Survives cluster destroy | PITR | Cost |
|---|---|---|---|
| SQLite | No | No | 0 — but forbids KubernetesExecutor |
| **In-cluster Postgres + PVC** | No | No | ~EUR 1/month (disk) |
| Flexible Server B1ms | Yes | 7 days | ~EUR 13/month |

**Why.** SQLite is disqualified outright: it permits only one writer, so it
forces SequentialExecutor and eliminates the KubernetesExecutor entirely.
Between the other two, EUR 13/month is a quarter of this platform's total
budget, and what it buys is durability across an event — `make destroy` — that
this environment is explicitly designed for.

The PVC does survive pod restarts and `az aks stop/start`, which covers the
failure modes that actually happen day to day.

**Cost of the decision.** DAG run history, task state and connections are lost
when the cluster is destroyed. Acceptable because the DAGs are in git and the
data is in Delta — the metadata database holds no unique state worth recovering.

**Revisit if.** Anyone needs run history to survive a rebuild, or Airflow starts
holding connection configuration that is not reproducible from git.

---

## ADR-011 — Grafana OSS instead of Azure Managed Grafana {#adr-011}

**Decision.** `kube-prometheus-stack` with Grafana OSS in-cluster. Dashboards as
ConfigMaps, reloaded by the sidecar.

**Why.** Azure Managed Grafana is roughly EUR 45/month against a EUR 50 total
budget — the entire budget for one dashboard server. Grafana OSS costs the
128Mi it occupies. Metrics are already in the cluster, so the in-cluster option
also removes an export path.

Log Analytics is kept alongside it and is not redundant: Azure resource logs —
Databricks audit events, storage data-plane access, AKS control plane — are only
available there and Prometheus cannot see them. The split is by signal origin,
not preference.

**Cost of the decision.** No Entra SSO (access is `kubectl port-forward` plus an
admin password from a Kubernetes secret), no managed availability, no zone
redundancy. A node restart takes dashboards down. A dashboard edited in the UI
is lost on pod restart — deliberate, since the ConfigMaps are the source.

**Revisit if.** Dashboards are consumed by anyone outside the platform team. At
that point SSO and availability stop being optional and Managed Grafana is worth
its price.

---

## ADR-012 — Unity Catalog is the only authorisation point {#adr-012}

**Decision.** No human and no job holds an Azure RBAC data-plane role on the
lake. The only principal with storage access is the Access Connector managed
identity. Every read is authorised by a Unity Catalog grant, and every grant
targets an Entra group, never a user.

**Why.** Two authorisation systems over the same data means two places to review
and two places to get it wrong — and storage RBAC is the one that silently wins,
because a principal with `Storage Blob Data Reader` can read the Parquet files
directly and bypass every column mask and row filter that makes gold safe to
publish. Collapsing to one point makes "who can read this table" a question with
a single answer, and makes every read appear in one audit log.

Readers are excluded from bronze and silver entirely, and from `READ_FILES` on
any external location. Gold is the published interface.

**Cost of the decision.** Break-glass access is awkward by design — platform
admins hold `Storage Blob Data Contributor` on the lake for inspection, which is
the one exception and is time-bound through PIM in production. Debugging a
malformed file sometimes needs that exception.

**Revisit if.** A tool that cannot speak Unity Catalog becomes load-bearing. The
answer is usually a Delta Sharing recipient rather than a storage role.

---

## ADR-013 — GitHub Actions and Azure DevOps in parity {#adr-013}

**Decision.** Both pipelines exist, share the same Terraform version, the same
gates, and call the same scripts rather than reimplementing the logic.

**Why.** This repository lives on GitHub; PostNord-scale enterprises typically
run Azure DevOps. Maintaining both proves the platform is not bound to one CI
system, and calling shared scripts means the acceptance criterion is testable:
a service can move between CI platforms without its security posture changing.

**Cost of the decision.** Two pipeline definitions to keep in step. The
mitigation is that neither contains policy logic — both invoke `make` targets,
so a gate can only drift if someone edits one pipeline's target list.

**Revisit if.** One platform is decommissioned, or the pipelines start
diverging in substance rather than syntax.

---

## ADR-014 — Deferrable operators for every external wait {#adr-014}

**Decision.** Every Airflow task that waits on something outside the cluster —
a Databricks run, a file arrival — uses `deferrable=True`.

**Why.** A non-deferrable `DatabricksSubmitRunOperator` holds a worker pod for
the entire duration of the Databricks job. On a single 2 vCPU node that is
roughly two concurrent tasks total, so two four-hour jobs would block the
scheduler for four hours while doing nothing but waiting.

Deferred tasks release their pod and resume on the triggerer, which polls
asynchronously. One triggerer handles hundreds of waits in a single process.

**Cost of the decision.** The triggerer is a required extra component, and a
triggerer restart re-runs deferred triggers — so triggers must be idempotent.
Some third-party operators do not implement a deferrable path.

**Revisit if.** The node grows enough that pod slots stop being the binding
constraint, which would remove the need without making it wrong.

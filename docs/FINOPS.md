# FinOps

Cost model, attribution, and the levers that actually move the number.

The governing constraint on this platform is a Free Trial subscription with a
**spending limit on** — when the credit runs out, Azure disables services rather
than billing. Cost control here is not hygiene; exceeding it is an outage.

---

## 1. Where the money goes

Sandbox, month-to-date shape at rest:

| Component | ~EUR/month | Billing model | Lever |
|---|---:|---|---|
| AKS node — 1× `Standard_B2s_v2` | 28 | Per hour, running | `make stop` overnight |
| AKS control plane | 0 | Free tier | Standard is +65 |
| Managed disks — OS 64GB + 2 PVCs | 6 | Provisioned, always | Size down |
| ADLS Gen2 — LRS, low volume | 1 | Per GB + transactions | Lifecycle tiering |
| Log Analytics | 2–5 | Per GB ingested | 1 GB/day hard cap |
| ACR Basic | 4 | Flat | Prune untagged manifests |
| Key Vault | <1 | Per operation | — |
| Databricks workspaces (idle) | **0** | DBU only when running | — |
| Databricks serverless SQL | 0 at rest | Per second while querying | 10-min auto-stop |
| Public IP (AKS load balancer) | 3 | Flat | — |
| **Total at rest** | **~44** | | |

**Not present, and what each was avoided:**

| Avoided | ~EUR/month | Because |
|---|---:|---|
| Azure Managed Grafana | 45 | Grafana OSS in-cluster — [ADR-011](DECISIONS.md#adr-011) |
| API Management (Developer) | 45 | Removed during teardown; nothing needed it |
| AKS Standard tier | 65 | No SLA required on a lab |
| NAT gateway | 32 | Serverless Databricks does not egress here — [ADR-004](DECISIONS.md#adr-004) |
| Private endpoints × 5 | 35 | Storage firewall + service endpoints |
| Postgres Flexible Server | 13 | In-cluster Postgres — [ADR-010](DECISIONS.md#adr-010) |
| Private DNS zones × 5 | 3 | No endpoints to resolve |
| **Total avoided** | **~238** | |

The teardown that preceded this build removed roughly **EUR 90/month** of idle
spend — a Managed Grafana instance and a Developer-tier API Management service,
neither of which anything was using. Finding those is the highest-yield FinOps
activity there is, and it is why `make cost` reports untagged spend first.

---

## 2. Attribution: tags are the mechanism

Cost is only reducible if it is attributable. Four tags are mandatory, enforced
by Azure Policy and by Databricks cluster policy:

| Tag | Answers |
|---|---|
| `platform` | Is this ours at all? |
| `environment` | sandbox or prod |
| `domain` | Which data domain — logistics, platform |
| `cost-center` | Who is charged |

**Cluster policy tags are `fixed`, not `allowlist`.** A user who can edit the
`domain` tag can move their spend onto another team's cost centre — usually by
accident, when cloning someone else's cluster. Fixing the value removes the
possibility rather than detecting it afterwards.

```bash
make cost ENV=sandbox
```

`scripts/python/finops_report.py` groups actual cost by each tag and **reports
untagged spend first**. Anything in that bucket is the finding, not a rounding
error: it is spend nobody owns, which means it is spend nobody will reduce.

### What the first real run found

Running this against the live subscription is the reason this section exists.
Month-to-date, **99 percent of spend was untagged**:

| Resource type | Share | Tagged? | Why |
|---|---:|---|---|
| VM scale set (AKS nodes) | 78% | no | AKS-managed, in the node resource group |
| Managed disks (PVCs) | 7% | no | Created by the CSI driver, not Terraform |
| Public IP, load balancer | 3% | no | AKS-managed |
| Everything Terraform creates | 1% | **yes** | — |

The Azure Policy compliance view had reported the platform as broadly compliant,
because it evaluates the resources Terraform creates. It cannot see that the
majority of *spend* sits in resources Terraform never touches.

Two things follow, and both are now in the repository:

1. **`kubernetes/platform/storageclass.yaml`** — a storage class carrying the
   cost-attribution tags, which the CSI driver copies onto every disk it
   creates. This is the only place those tags can come from.
2. **The AKS node resource group is a known, permanent gap.** The scale set and
   load balancer are created by the AKS resource provider and cannot be tagged
   from Terraform. Treat that line as platform overhead attributed to
   `data-platform`, not as an attribution failure to chase.

The lesson generalises: *policy compliance is not cost attribution.* A platform
can be fully compliant and still have most of its bill unowned.

---

## 3. The levers, by yield

**1. Do not run compute you are not using.** The single largest lever.

```bash
make stop  ENV=sandbox   # ~60% off the monthly bill
make start ENV=sandbox
```

A stopped AKS cluster keeps its configuration and its disks and stops billing
for nodes. On a platform used in bursts this is worth more than every other
optimisation combined.

**2. Cluster policies, not good intentions.** Everything expensive about
Databricks is a cluster setting, so `terraform/modules/databricks-compute` is
the highest-leverage file in the repo for cost:

| Control | Value | Prevents |
|---|---|---|
| `autotermination_minutes` | max 30, default 20 | The idle interactive cluster — the classic Databricks bill |
| `node_type_id` | allowlist of 2 | A 48-core node selected for a job that reads a CSV |
| `autoscale.max_workers` | max 4 | A runaway job eating the regional quota |
| `azure_attributes.availability` | `SPOT_WITH_FALLBACK` | Full on-demand price on retryable work |
| `first_on_demand` | 1 | Spot driver eviction losing the whole run |

Thirty minutes rather than sixty is deliberate: across a team of ten, that
difference is thousands of DBU a month spent on nothing.

**3. Serverless auto-stop.** The SQL warehouse costs nothing while stopped and
stops after 10 minutes idle. Ten is the practical floor — lower and an analyst
pays the cold-start penalty between queries, which trades money for
irritation and usually loses.

**4. Storage lifecycle.** Storage is the cost that only ever grows, and grows
silently — nobody files a ticket because bronze is three years old.

| Layer | Rule | Rationale |
|---|---|---|
| `landing` | Delete at 30 days | Anything unignested by then is a pipeline failure already alerted on |
| `bronze` | Cool at 30d, archive at 180d **since last access**, delete at 7 years | Tiering on access keeps queried partitions hot |
| `silver`, `gold` | Cool at 180d since last access, **never archived** | A dashboard failing because a partition is in archive is an outage to the person looking at it |
| `checkpoints` | **No rule at all** | Structured Streaming reads its checkpoint every microbatch; a cold one adds latency, an archived one stalls the stream |

Last-access tracking is enabled on the account specifically to make these rules
possible — tiering on creation date would demote partitions that are still being
read, and every subsequent read pays a retrieval charge.

**5. Log Analytics daily cap.** 1 GB/day, hard. This is the one control that can
cause the outage it prevents: when hit, ingestion stops until 00:00 UTC and the
platform goes blind. Accepted because uncapped ingestion from a log-looping pod
could exhaust the credit and take down everything. The `alert-ingest-near-cap`
rule fires at 80 percent so there is time to find the noisy source rather than
just raise the cap — raising it usually just pays for the bug.

---

## 4. Budget alerts

```
50%  forecast   something is running that should not be
90%  forecast   on track to exceed before month end
80%  actual     act now — park the cluster
100% actual     already over; the credit is finite
```

**The budget amount is in the subscription's billing currency, and Azure
budgets have no currency field.** This subscription bills in **SEK** while
every figure in this document is EUR. A budget set to `50` meaning "EUR 50"
became SEK 50 — roughly five times tighter than intended — and reported a
platform operating normally as 489 percent over budget. The default is now
SEK 550, which is about EUR 50. Confirm the billing currency before changing
it; the command is in the variable's own documentation.

Forecast thresholds come first deliberately. By the time *actual* crosses 80
percent there may be two days left in the month; a forecast breach on day four
is still actionable.

**Azure budgets notify. They do not stop spend.** Stated here because believing
otherwise is discovered in the month it matters. What stops spend on this
subscription is the Free Trial spending limit, and it stops it by disabling
services — a platform outage, not a cost control.

---

## 5. What a FinOps review should ask

1. **What is in the untagged bucket?** Anything there is unowned. Start here.
2. **What is running that nobody queried this week?** Cross-reference the
   Databricks audit log against the DBU report.
3. **Is any cluster policy set to `allowlist` where it should be `fixed`?**
   `make policy-test` answers this in CI, on every pull request.
4. **What is the cool/hot split in the lake?** If everything is hot, the
   lifecycle rules are not matching the prefixes they think they are.
5. **Which line grew fastest month over month?** Absolute cost is less
   informative than its derivative.

---

## 6. What this design would cost at PostNord scale

The sandbox figures are not a forecast. Scaled to a real platform — say 8
domains, 200 users, several TB — the shape changes and the levers change with
it:

| Line | Becomes | Dominant lever |
|---|---|---|
| Databricks DBU | The largest line by far | Cluster policies, serverless, spot, right-sized runtimes |
| Storage | Second largest, grows monotonically | Lifecycle tiering, small-file compaction |
| AKS | Roughly flat | Reserved instances, spot node pools |
| Log Analytics | Grows with domain count | Category selection, basic logs tier, archive to lake |
| Networking | Egress becomes visible | Private endpoints, regional co-location |

At that scale, a one-year reserved instance commitment on the AKS pool and a
Databricks pre-purchase (DBCU) are the two decisions worth making, and neither
makes sense at sandbox volume.

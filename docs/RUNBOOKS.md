# Runbooks

Every alert in `terraform/modules/observability/alerts.tf` names an anchor here.
An alert that does not tell the person woken up what to do is an alert that
trains them to ignore the channel.

Each runbook states: what the alert means for a user, how to confirm, how to
fix, and how to stop it recurring.

---

## Job failure {#job-failure}

**Alert:** `alert-dbx-job-failure` · severity 1 · pages

**What it means.** A Databricks job run failed. A table downstream of it is not
being produced, which downstream of *that* is a stale report or a missing data
product.

**Confirm.**

```kusto
DatabricksJobs
| where TimeGenerated > ago(1h)
| where ActionName in ("runFailed", "runTaskFailed")
| project TimeGenerated, ActionName, RequestParams, Response
| order by TimeGenerated desc
```

Then open the run in the workspace UI — the driver log has the actual
exception, which the audit log does not.

**Fix.** By cause:

| Cause | Signature | Action |
|---|---|---|
| Spot eviction | `SPOT_INSTANCE_TERMINATION` | Re-run. The policy already sets `first_on_demand: 1`; if drivers are being evicted, that is a bug |
| Bad data | Schema or constraint error | Do **not** re-run. Check `quarantine`, fix upstream, then re-run |
| Permission | `PERMISSION_DENIED` on a table | See [access denied](#access-denied) |
| Quota | `CLUSTER_LAUNCH_FAILURE` | `./scripts/bash/check-quota.sh sandbox` |
| Policy violation | `INVALID_PARAMETER_VALUE` naming a policy | The job asked for something the cluster policy forbids — fix the job, not the policy |

**Decide before re-running.** If the DAG has downstream tasks, hold them:
re-running a failed silver build while gold is already consuming the previous
partition produces a mixed result that is worse than a delay.

**Prevent.** A failure that recurs is a missing quality gate, not a flaky job.
Add the check to `quality_checks` so it fails between silver and gold rather
than at publication.

---

## Access denied {#access-denied}

**Alert:** `alert-uc-access-denied` · severity 2 · ticket

**What it means.** More than ten Unity Catalog permission denials from one
principal in an hour. Either a domain onboarding is missing a grant, or someone
is probing catalogs they should not see. Both need a human; neither needs one at
03:00.

**Confirm.**

```kusto
DatabricksUnityCatalog
| where TimeGenerated > ago(6h)
| extend ResponseJson = parse_json(Response)
| where toint(ResponseJson.statusCode) !in (200, 201)
| summarize Denials = count(), Objects = make_set(RequestParams, 20)
    by Principal = tostring(parse_json(tostring(Identity)).email)
| order by Denials desc
```

**Triage.** The question is whether the principal *should* have the access.

- **Should have it** — a grant is missing. Do not fix it in the workspace UI;
  that creates drift `make drift` will report forever. Add the principal to the
  right Entra group, or add the grant to
  `terraform/envs/sandbox-databricks/main.tf` and apply.
- **Should not have it** — treat as a security event. Capture the audit rows,
  disable the principal, and escalate. Do not clean up the evidence first.

**Common false positive.** A newly created group that SCIM has not yet
synchronised. See [SCIM provisioning](#scim-provisioning).

---

## Lake authorisation failure {#lake-auth-failure}

**Alert:** `alert-lake-auth-failure` · severity 2 · ticket

**What it means.** More than 25 authorisation failures against the data lake in
an hour. The lake denies by default at the network layer and grants nothing
directly to humans, so this is either a workload that lost its identity or
something knocking that should not be.

**Check the boring cause first.** A failed `terraform apply` that removed a role
assignment looks identical from here to an attack, and is far more likely.

```bash
az role assignment list --scope "$(terraform -chdir=terraform/envs/sandbox output -raw storage_account_id)" \
  --query "[].{role:roleDefinitionName, principal:principalId}" -o table
```

Expect exactly: the two Access Connector identities (`Storage Blob Data
Contributor`), the Airflow identity (`Storage Blob Data Reader`), and the
platform admins group.

**If a grant is missing:** `make plan ENV=sandbox` will show it. Apply.

**If the caller is unrecognised:** check `CallerIpAddress` in the alert. The
storage firewall should have refused it before authentication — a caller that
got as far as an authorisation failure came from an allowed subnet or the
operator IP, which narrows it considerably.

---

## Ingestion near cap {#ingestion-cap}

**Alert:** `alert-ingest-near-cap` · severity 2 · ticket

**What it means.** Log Analytics ingestion has passed 80 percent of the 1 GB
daily cap. **When the cap is hit, ingestion stops until 00:00 UTC and this
platform goes blind.**

**Find the source before raising the cap.** Raising it usually just pays for a
bug.

```kusto
Usage
| where TimeGenerated > ago(24h) and IsBillable
| summarize GB = sum(Quantity) / 1000 by DataType
| order by GB desc
```

| Dominant table | Likely cause | Action |
|---|---|---|
| `ContainerLogV2` | A pod in a crash loop, or debug logging left on | Fix the pod. This is the usual answer |
| `AzureDiagnostics` / `DatabricksClusters` | Cluster churn from a job spinning up repeatedly | Look for a retry loop |
| `StorageBlobLogs` | A job listing the lake in a loop | Usually a misconfigured sensor |
| `KubeAuditAdmin` | Something reconciling aggressively | Check for a controller in a loop |

**Only then decide.** If the volume is legitimate growth, raise
`daily_quota_gb` in `terraform/envs/sandbox/main.tf` and accept the cost — but
record why, because the cap exists to protect a spending limit that disables
the whole platform.

---

## SCIM provisioning {#scim-provisioning}

**Symptom.** A Terraform apply of the Databricks root fails with
`Could not find principal with name yoda-...`, or Unity Catalog grants do not
appear even though the Entra group plainly exists.

**Cause.** Entra groups do not exist in Databricks until SCIM synchronises them
into the *account*. Terraform can only name a principal Databricks already
knows about. This is why `enable_grants` defaults to `false` — see
[ADR-007](DECISIONS.md#adr-007).

**Fix, once per tenant.**

1. `https://accounts.azuredatabricks.net` → Settings → User provisioning.
2. Generate a SCIM token and endpoint URL.
3. In Entra: Enterprise applications → Azure Databricks SCIM Provisioning
   Connector → provision the five `yoda-*` groups.
4. Wait for the first sync cycle — up to 40 minutes.
5. Confirm the groups are visible in the Databricks account console.
6. Set `enable_grants = true` in
   `terraform/envs/sandbox-databricks/terraform.tfvars` and apply.

**Do not** work around this by granting to individual users. Every grant in this
platform targets a group — see [ADR-012](DECISIONS.md#adr-012).

---

## Quota exhausted {#quota}

**Symptom.** AKS node pool will not scale, pods stay `Pending`, or a Terraform
apply fails midway through creating a cluster.

**Confirm.**

```bash
./scripts/bash/check-quota.sh sandbox
```

**The arithmetic.** Sweden Central allows 4 vCPU on this subscription. AKS at
its ceiling of 2 × `Standard_B2s_v2` is exactly 4. There is no headroom for a
classic Databricks cluster, which needs a 4-vCPU node minimum.

**Options, cheapest first.**

1. `make stop ENV=sandbox` — frees the nodes, keeps everything else.
2. `enable_aks = false` — deploys the entire data platform with no compute. Lake,
   Databricks, Unity Catalog and governance all still work.
3. Request an increase — not available on Free Trial subscriptions.

**Do not** raise `node_count_max` above 2. The autoscaler will keep requesting
capacity Azure keeps refusing, and the symptom becomes permanently `Pending`
pods with a confusing event log.

---

## Cluster cannot reach the control plane {#classic-egress}

**Symptom.** A classic (VNet-injected) Databricks cluster times out during
launch. The error names the control plane, not the network.

**Cause.** Azure retired default outbound access for VNets created after
30 September 2025. `enable_nat_gateway = false` in sandbox, because serverless
compute egresses from Databricks' own network and needs nothing here — so the
first classic cluster anyone starts has no internet path at all.

**Fix.**

```hcl
# terraform/envs/sandbox/main.tf
enable_nat_gateway = true   # ~EUR 32/month plus data processing
```

Everything else — the injected subnets, the documented NSG egress rules, the
zone-redundant public IP — already exists. See
[ADR-004](DECISIONS.md#adr-004).

---

## Restoring the platform {#rebuild}

**Full rebuild from an empty subscription:**

```bash
make bootstrap
make backend-config ENV=sandbox && make tfvars ENV=sandbox
make quota ENV=sandbox
make apply ENV=sandbox
./scripts/bash/check-metastore.sh sandbox
make apply ENV=sandbox-databricks
make kubeconfig ENV=sandbox && make platform-deploy ENV=sandbox
```

**Order matters.** `sandbox-databricks` reads `sandbox`'s outputs from remote
state. **Destroying reverses it** — the Databricks root first, or its external
locations outlive the storage account they point at:

```bash
make destroy ENV=sandbox-databricks
make destroy ENV=sandbox
```

**What is lost in a rebuild:** Airflow run history and task state (in-cluster
Postgres, [ADR-010](DECISIONS.md#adr-010)), Grafana's admin password
(regenerated), and Prometheus history. What survives: the DAGs, all
infrastructure definitions, and every Delta table in the lake — because none of
those live in the cluster.

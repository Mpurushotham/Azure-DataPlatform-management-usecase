# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this repository is

Infrastructure-as-code only — an Azure + Databricks data platform (networking,
data lake, Unity Catalog, Kubernetes, orchestration, governance, observability)
built with **Terraform**, **Helm**, **Python** and **Bash**. There is no
application code and no unit-test suite; "testing" means `terraform validate`,
`tflint`, `trivy config`, the cluster-policy contract check, and a DAG import
check.

Two things are unusual and drive most decisions:

1. **The sandbox environment is genuinely deployed** against a live Free Trial
   subscription with a **4 vCPU regional quota** and a spending limit that
   *disables services* when credit runs out. Cost control is an availability
   control here.
2. **`terraform/envs/prod` has never been applied.** It is code-complete and
   validated. Do not describe it as deployed.

## Commands

```bash
make check                       # everything CI runs, in CI order
make fmt-check lint validate     # Terraform gates individually
make scan                        # trivy config, CRITICAL blocks
make policy-test                 # Databricks cluster-policy security contract
make dag-test                    # Airflow DAG import check

make quota  ENV=sandbox          # will this fit? 2s, vs 12min into a failed apply
make plan   ENV=sandbox
make apply  ENV=sandbox
make output ENV=sandbox

make kubeconfig      ENV=sandbox
make platform-deploy ENV=sandbox # Airflow + Prometheus + Grafana via Helm

make cost   ENV=sandbox          # month-to-date by tag; untagged spend first
make drift  ENV=sandbox          # Unity Catalog grants added outside Terraform
make stop / make start           # park the cluster, ~60% off the bill
```

## Apply order — this matters

Two Terraform roots over one environment, and the order is not optional:

```
terraform/envs/sandbox              foundation, Databricks workspaces, AKS
terraform/envs/sandbox-databricks   Unity Catalog, cluster policies, warehouses
```

The second reads the first's outputs from remote state. The split exists
because the `databricks` provider needs a `host` that is a workspace URL, and a
provider cannot depend on a resource created in its own apply (ADR-008).

**Destroy reverses it** — Databricks root first, or its external locations
outlive the storage account they point at.

## Repository map

| Path | Holds |
|---|---|
| `terraform/bootstrap/` | State containers + CI federated identity. Run once, local state |
| `terraform/modules/` | 10 modules. Never applied directly |
| `terraform/envs/sandbox/` | Deployed |
| `terraform/envs/sandbox-databricks/` | Deployed |
| `terraform/envs/prod/` | Code-complete, **never applied** |
| `kubernetes/` | Helm values and manifests. Applied by `scripts/bash/deploy-platform.sh`, not Terraform |
| `policies/databricks/` | Cluster-policy security contract as JSON. Terraform reads it; CI asserts it |
| `dags/` | Airflow DAGs, baked into the image |
| `docs/` | 15 documents. `DECISIONS.md` is the one to read first |

## Conventions

**Comments explain the trade-off, not the syntax.** Every module header states
what the alternative was and why it lost. If a setting has a cost, the comment
names the number. Match this — a comment restating the resource name is noise.

**ADRs carry a revisit trigger.** A decision with no stated trigger for
revisiting is one nobody can safely change later. New significant decisions go
in `docs/DECISIONS.md` in that form.

**Plan-time booleans, not string comparisons.** `count` cannot depend on a value
another module produces. Use `enable_diagnostics`-style flags rather than
`var.something != ""` — the failure is `Invalid count argument` and it is
confusing.

**Grants target groups, never users.** Every Unity Catalog grant and Azure role
assignment names an Entra group. `scripts/python/uc_drift.py` fails the build on
anything else.

**Nothing stores a secret.** OIDC federation for CI, workload identity for pods,
Access Connector for Unity Catalog, `shared_access_key_enabled = false` on the
lake. If a change needs a stored credential, that is a design problem first.

## Gotchas that have already cost time

Recorded in `docs/BUILD-LOG.md` with root causes. The ones most likely to recur:

- **Storage firewalls reject `/32`.** Uniquely among Azure firewalls. Normalised
  in `modules/data-lake` — write CIDR at the call site.
- **Unity Catalog external locations may not overlap.** They are
  metastore-scoped. Each domain owns `abfss://{layer}@lake/{domain}/`, never a
  container root.
- **`isolation_mode` has two spellings.** `ISOLATION_MODE_*` on credentials and
  external locations; bare `ISOLATED` on catalogs.
- **AKS versions age into `AKSLongTermSupport`** and are then rejected. Check
  `az aks get-versions` for `KubernetesOfficial` before pinning.
- **ACR Tasks is unavailable on this subscription** and *queues* before failing,
  so it reads as a hang. Build locally with `--platform linux/amd64`.
- **Pin images by digest, not tag.** With `IfNotPresent`, a node holding a
  cached tag never re-pulls, and the deployment silently runs old code.
- **A 2 vCPU node cannot roll a Deployment.** Use `strategy: Recreate`.
- **Trivy ignore `paths` are relative to the scan root** (`modules/...`, not
  `terraform/modules/...`). A wrong path matches nothing, silently.

## Boundaries

- **Never commit** `terraform.tfvars`, `backend.hcl`, `*.tfstate`, or kubeconfig.
  All are gitignored; verify before staging.
- **Never provision through an MCP tool call.** The `azure` MCP server inherits
  an Owner-scoped `az login`. Infrastructure changes go through Terraform and a
  reviewed plan. See `.mcp.json` and `docs/MCP.md`.
- **Do not add a Claude co-author trailer to commits.** Commits are authored by
  the repository owner.
- **Do not describe `prod` as deployed**, or Unity Catalog grants as applied —
  grants are off pending SCIM. `docs/COVERAGE.md` lists every gap.

## Cost awareness

This environment bills by the hour against a finite credit. Before suggesting a
change that adds standing cost, state the monthly figure. `make stop` is
usually the right answer to "we are not using it right now".

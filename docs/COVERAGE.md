# Requirement coverage

Traceability from the PostNord *Platform Engineer (Infra), Data Platform Team*
brief to the artefact that addresses it.

**Legend** — `applied`: deployed and verified against live Azure ·
`code`: written, validated and linted, not applied here ·
`design`: documented with a build path, not implemented.

---

## Must-have requirements

| Requirement | Level | Status | Where |
|---|---|---|---|
| Azure infrastructure | 4 | applied | `terraform/modules/*` — 10 modules, 2 environment roots; 6 resource groups live in Sweden Central |
| Azure Databricks administration | 4 | applied | Premium workspaces, VNet injection, Secure Cluster Connectivity, Unity Catalog metastore, catalogs, external locations, storage credentials, cluster policies, serverless SQL warehouses |
| Airflow | 4 | applied | `kubernetes/airflow/` KubernetesExecutor + triggerer; `dags/logistics_medallion.py` deferrable operators, arrival sensor, quality gate |
| Terraform | 4 | applied | 10 modules, remote state, partial backends, `for_each` composition, plan-time-safe conditionals, provider aliasing |
| Kubernetes | 4 | applied | AKS CNI Overlay + Cilium, workload identity, Entra RBAC, `local_account_disabled`, Pod Security `restricted`, default-deny NetworkPolicy, PDB/HPA |
| Git & CI/CD | 4 | code | `.github/workflows/` + `azure-pipelines/` in parity, OIDC federation, gated apply — [ADR-013](DECISIONS.md#adr-013) |
| Infrastructure as Code | 4 | applied | Everything above; nothing created by hand except the metastore — [ADR-007](DECISIONS.md#adr-007) |
| Azure Networking | 4 | applied | Hub VNet, delegated Databricks subnets, per-trust-level NSGs, service endpoints, private DNS + endpoints (code), NAT gateway (code) — [NETWORK-CIA.md](NETWORK-CIA.md) |
| Security & Compliance | 4 | applied | No stored secrets, Entra-only storage, Azure Policy baseline enforcing, audit diagnostics — [SECURITY.md](SECURITY.md) |
| Entra ID / IAM | 3 | applied | 5 security groups, 3 workload identities, federated credentials, group-only grants — `modules/identity` |
| Monitoring & Observability (Grafana) | 3 | applied | Grafana OSS + Prometheus in-cluster, Log Analytics, 4 symptom-based alerts, 2 action groups — [OBSERVABILITY.md](OBSERVABILITY.md) |
| Python, PowerShell or Bash | 3 | applied | `scripts/python/` FinOps report, policy contract validator, DAG validator; `scripts/bash/` quota preflight, metastore check, deployment |
| Platform Reliability & Operations | 4 | applied | Symptom alerting, runbook per alert, DR design, quota preflight — [RUNBOOKS.md](RUNBOOKS.md) · [DR.md](DR.md) |
| Cost Optimization (FinOps) | 4 | applied | Cluster policies with fixed tags, serverless auto-stop, lifecycle tiering, budget with forecast alerts, tag-attributed cost report — [FINOPS.md](FINOPS.md) |

## Named work tasks

| Task | Status | Where |
|---|---|---|
| Maintain and enhance the Airflow infrastructure | applied | `kubernetes/airflow/`, `docker/airflow/`, `dags/` |
| Resilient, scalable, secure network on CIA principles | applied | [NETWORK-CIA.md](NETWORK-CIA.md) — every control mapped to what it defends and how it fails |
| Monitor health, availability, performance and cost (Grafana, Defender, Azure Monitor) | applied | Grafana OSS, Log Analytics, Defender CSPM enabled; Defender for Storage/Containers in prod tfvars |
| **YODA migration West Europe → Sweden Central** | design | [MIGRATION-YODA.md](MIGRATION-YODA.md) — 8 phases, cutover sequence, validation gate, rollback, risk register |
| Disaster recovery planning | design | [DR.md](DR.md) — RTO/RPO per component, `DEEP CLONE` strategy |
| Incident response, troubleshooting, RCA | applied | [RUNBOOKS.md](RUNBOOKS.md) — every alert description links to its runbook anchor |
| Platform standards, guardrails, reusable capabilities | applied | Azure Policy baseline, cluster policy JSON contract, module library, [ONBOARDING-DOMAIN.md](ONBOARDING-DOMAIN.md) |
| MLOps and model deployment infrastructure | design | [MLOPS.md](MLOPS.md) — Unity Catalog model registry, serving path |
| Act as SME, mentor on best practices | applied | 14 ADRs with cost and revisit triggers; every module header explains the trade-off, not the syntax |

## Nice-to-have

| Requirement | Status | Note |
|---|---|---|
| Microsoft Purview | design | Container-level `classification` metadata already set to drive scan scope; provider not registered on this subscription |
| MLOps | design | [MLOPS.md](MLOPS.md) |
| Azure AI services | not covered | Out of scope for the platform layer |
| Multi-cloud experience | not covered | Deliberately Azure-only here |
| Logistics industry context | applied | `logistics` domain modelled end to end — shipment medallion pipeline, domain catalog, domain groups |

---

## What is deployed right now

Verified live in subscription `6b1fb7ca…`, Sweden Central:

```
rg-yoda-sandbox-network         VNet 10.60.0.0/16, 6 subnets, 3 NSGs
rg-yoda-sandbox-data            ADLS Gen2 (HNS, Entra-only), 7 containers, lifecycle policy
rg-yoda-sandbox-databricks      2 Premium workspaces (SCC, VNet-injected), 2 Access Connectors
rg-yoda-sandbox-compute         AKS 1.34, Free tier, 1x B2s_v2, Cilium, workload identity
rg-yoda-sandbox-observability   Log Analytics (1 GB/day cap), 4 alerts, 2 action groups
rg-yoda-sandbox-security        Key Vault (RBAC), ACR Basic, 3 managed identities

Unity Catalog   metastore_azure_swedencentral
                yoda_sandbox_platform    · bronze/silver/gold
                yoda_sandbox_logistics   · bronze/silver/gold
                4 cluster policies, 2 serverless SQL warehouses

Entra           yoda-platform-admins · yoda-data-engineers · yoda-data-analysts
                yoda-domain-logistics-readers · yoda-domain-logistics-writers

Governance      yoda-sandbox-baseline initiative, enforcing, 5 policies
                EUR 50/month budget, forecast + actual alerts
```

**vCPU usage: 2 of 4.** Headroom preserved deliberately — see
[ADR-003](DECISIONS.md#adr-003).

---

## Honest gaps

Listed because a coverage matrix with no gaps is not a coverage matrix.

| Gap | Why | Cost to close |
|---|---|---|
| Private endpoints and private DNS off | ~EUR 7 per endpoint per month against a EUR 50 budget | One tfvar; prod already sets it |
| `prod` never applied | No subscription with the quota or budget | An apply and a teardown |
| Unity Catalog grants not applied | SCIM has not synchronised Entra groups into the Databricks account | Configure SCIM, set `enable_grants = true` |
| Purview not deployed | Resource provider not registered; adds standing cost | Register provider, add module |
| No classic Databricks compute | Would consume the entire 4 vCPU quota | Quota increase, then `enable_nat_gateway = true` |
| Customer-managed keys | Needs a Premium Key Vault and HSM | In prod tfvars, unproven |
| Azure Firewall / Bastion | Subnets reserved, not deployed | ~EUR 900/month combined |
| MLOps implemented | Designed only | A workspace model-registry module |

# Architecture — visual reference

Top-to-bottom service view of the YODA Data Platform, from consumers down to
the platform foundation, with the concrete Azure resource behind every box.

**Rendering note.** GitHub's Mermaid renderer cannot load external icon packs,
so these diagrams name services rather than drawing their icons. A fully
iconographic rendering of the same architecture is published separately — see
[§7](#7-iconographic-rendering).

Companion documents: [ARCHITECTURE.md](ARCHITECTURE.md) for flows and rationale,
[SOLUTION-DESIGN.md](SOLUTION-DESIGN.md) for the design-authority view.

---

## 1. Layered view — top to bottom

```mermaid
flowchart TB
    classDef consume fill:#e8f0fe,stroke:#1a73e8,color:#0b3d91
    classDef govern  fill:#e6f4ea,stroke:#137333,color:#0d652d
    classDef process fill:#fef7e0,stroke:#ea8600,color:#8a5300
    classDef orch    fill:#f3e8fd,stroke:#8430ce,color:#4a148c
    classDef store   fill:#e4f7fb,stroke:#007b8a,color:#004d57
    classDef found   fill:#f1f3f4,stroke:#5f6368,color:#202124

    subgraph C["① CONSUMPTION"]
        direction LR
        C1["Power BI · reporting"]
        C2["Data products<br/>Delta Sharing"]
        C3["ML / AI<br/>notebooks · serving"]
        C4["Databricks SQL<br/>serverless warehouse"]
    end

    subgraph G["② GOVERNANCE"]
        direction LR
        G1["Azure Databricks<br/>Unity Catalog metastore"]
        G2["Catalogs · schemas<br/>grants · lineage"]
        G3["Microsoft Entra ID<br/>groups · workload identity"]
    end

    subgraph P["③ PROCESSING"]
        direction LR
        P1["Databricks workspace<br/>yoda-sandbox-central"]
        P2["Databricks workspace<br/>yoda-sandbox-logistics"]
        P3["Serverless jobs<br/>+ cluster policies"]
    end

    subgraph O["④ ORCHESTRATION & OBSERVABILITY"]
        direction LR
        O1["Azure Kubernetes Service<br/>aks-yoda-sandbox"]
        O2["Apache Airflow<br/>KubernetesExecutor"]
        O3["Prometheus + Grafana OSS"]
        O4["Azure Container Registry<br/>Airflow image"]
    end

    subgraph S["⑤ STORAGE"]
        direction LR
        S1["ADLS Gen2 · HNS<br/>styodasandbox…"]
        S2["landing → bronze → silver → gold"]
        S3["quarantine · checkpoints · metastore"]
    end

    subgraph F["⑥ PLATFORM FOUNDATION"]
        direction LR
        F1["Virtual Network<br/>10.60.0.0/16 · NSGs"]
        F2["Azure Key Vault<br/>RBAC-authorised"]
        F3["Azure Policy<br/>enforcing baseline"]
        F4["Log Analytics<br/>audit · diagnostics"]
        F5["Cost Management<br/>budget + forecast"]
    end

    C --> G --> P --> S
    O --> P
    F -.-> G & P & O & S

    class C1,C2,C3,C4 consume
    class G1,G2,G3 govern
    class P1,P2,P3 process
    class O1,O2,O3,O4 orch
    class S1,S2,S3 store
    class F1,F2,F3,F4,F5 found
```

| Layer | Azure service | Deployed resource |
|---|---|---|
| ① Consumption | Databricks SQL (serverless) | 2 warehouses, 2X-Small, 10-min auto-stop |
| ② Governance | Unity Catalog · Entra ID | `metastore_azure_swedencentral`, 2 catalogs, 5 groups |
| ③ Processing | Azure Databricks Premium | 2 VNet-injected workspaces, SCC, 4 cluster policies |
| ④ Orchestration | AKS · ACR | 1.34 Free tier, 1× `Standard_B2s_v2`, ACR Basic |
| ⑤ Storage | ADLS Gen2 | HNS, 7 containers, lifecycle tiering |
| ⑥ Foundation | VNet · Key Vault · Policy · Log Analytics · Budgets | 6 subnets, 3 NSGs, enforcing baseline, 1 GB/day cap |

---

## 2. Network topology

```mermaid
flowchart TB
    NET["Virtual Network — vnet-yoda-sandbox<br/>10.60.0.0/16 · Sweden Central"]

    subgraph SN1["snet-platform · 10.60.0.0/24 — trust: platform"]
        AKSN["AKS node pool<br/>service endpoints: Storage, KeyVault, ACR"]
    end
    subgraph SN2["snet-dbx-central · 10.60.16.0/24 + .17.0/24 — trust: workload"]
        DBC["Databricks central<br/>host + container, delegated"]
    end
    subgraph SN3["snet-dbx-logistics · 10.60.18.0/24 + .19.0/24 — trust: workload"]
        DBL["Databricks logistics<br/>host + container, delegated"]
    end
    subgraph SN4["snet-privatelink · 10.60.1.0/24 — trust: restricted"]
        PE["Private endpoint NICs<br/>prod only"]
    end

    NET --- SN1 & SN2 & SN3 & SN4

    NSG1["nsg-platform<br/>DenyAllInbound 4000"] -.-> SN1
    NSG2["nsg-dbx<br/>DenyAllInbound 4000<br/>egress by service tag"] -.-> SN2 & SN3
    NSG3["nsg-pl<br/>DenyAllInbound 4000"] -.-> SN4

    LAKE[("ADLS Gen2<br/>default_action = Deny")]
    SN1 -->|service endpoint| LAKE
    SN2 -->|service endpoint| LAKE
    SN3 -->|service endpoint| LAKE

    LB["Standard Load Balancer<br/>outbound for AKS"] --- SN1
    NAT["NAT Gateway<br/>zone-redundant · prod only"] -.- SN2 & SN3
```

Databricks egress is allowed by **service tag**, not address range, so the rules
survive Azure re-IPing its own services:

| Priority | Destination | Port | Purpose |
|---|---|---|---|
| 200 | `VirtualNetwork` | any | Worker-to-worker (Spark shuffle) |
| 210 | `AzureDatabricks` | 443 | Control plane + SCC tunnel |
| 220 | `Sql` | 3306 | Legacy Hive metastore |
| 230 | `Storage` | 443 | The lake |
| 240 | `EventHub` | 9093 | Log and metric delivery |
| 250 | `AzureActiveDirectory` | 443 | Token acquisition |
| 4000 | any | any | **Deny** — inbound always; outbound when strict egress on |

Full rationale, including what each control defends and how it fails:
[NETWORK-CIA.md](NETWORK-CIA.md).

---

## 3. Identity and trust chain

```mermaid
flowchart TB
    subgraph HUMANS["People"]
        U["User"] --> GRP["Entra security group<br/>yoda-domain-logistics-readers"]
    end

    subgraph CI["CI/CD"]
        GH["GitHub Actions"] -->|OIDC| FIC1["Federated credential<br/>repo:…:environment:sandbox"]
        ADO["Azure DevOps"] -->|WIF| FIC1
        FIC1 --> MI1["id-yoda-terraform<br/>Owner on subscription"]
    end

    subgraph WORK["Workloads"]
        POD["Airflow pod<br/>SA: airflow"] -->|projected token| FIC2["Federated credential<br/>system:serviceaccount:airflow:airflow"]
        FIC2 --> MI2["id-yoda-sandbox-airflow"]
        DBX["Databricks"] --> AC["Access Connector<br/>system-assigned MI"]
    end

    GRP -->|UC grant| CAT[("Unity Catalog")]
    CAT -->|only path to data| LAKE[("ADLS Gen2")]
    AC -->|Storage Blob Data Contributor| LAKE
    MI2 -->|Storage Blob Data Reader<br/>landing only| LAKE
    MI1 -->|provisions| ALL["All resources"]

    U -.->|"no direct grant<br/>anywhere"| LAKE

    style LAKE stroke:#137333,stroke-width:2px
```

**No secret exists at any point in this chain.** Everything is a federated or
managed identity. `shared_access_key_enabled = false` removes the storage key
entirely — see [SECURITY.md](SECURITY.md).

---

## 4. Data flow with the services that move it

```mermaid
flowchart LR
    SRC["Source systems<br/>ERP · TMS · partner SFTP"]

    subgraph LAKE["Azure Data Lake Storage Gen2"]
        LND["landing<br/>expire 30d"]
        BRZ["bronze<br/>cool 30d · archive 180d"]
        SLV["silver<br/>cool 180d"]
        GLD["gold<br/>never archived"]
        QAR["quarantine"]
    end

    AF["Airflow DAG<br/>logistics_medallion"]
    DBX["Databricks serverless job<br/>under job cluster policy"]
    GATE{"quality gate"}

    SRC --> LND
    AF -->|"1 arrival sensor<br/>deferrable"| LND
    AF -->|"2 submit run"| DBX
    DBX --> BRZ --> SLV --> GATE
    GATE -->|pass| GLD
    GATE -->|fail| QAR
    GLD --> OUT["Reporting · data products · ML"]

    style GATE stroke:#c5221f,stroke-width:2px
    style GLD stroke:#137333,stroke-width:2px
```

The gate sits **between silver and gold**, not after gold: publishing a bad
table and alerting afterwards means consumers have already read it.

---

## 5. Observability signal paths

```mermaid
flowchart LR
    subgraph CLUSTER["In-cluster — free"]
        AFM["Airflow → statsd"] --> PROM[("Prometheus<br/>7d")]
        NODE["node-exporter"] --> PROM
        KSM["kube-state-metrics"] --> PROM
        PROM --> GRAF["Grafana OSS<br/>dashboards as ConfigMaps"]
    end

    subgraph AZURE["Azure resource logs — per GB"]
        DBXL["Databricks<br/>unityCatalog · jobs · clusters"] --> LAW[("Log Analytics<br/>30d · 1 GB/day cap")]
        STL["Storage read/write/delete"] --> LAW
        KVL["Key Vault AuditEvent"] --> LAW
        AKSL["AKS kube-audit-admin"] --> LAW
    end

    LAW --> ALERT["4 scheduled query alerts"]
    ALERT --> AG["Action groups<br/>page · ticket"]
    LAW -.->|datasource| GRAF
```

The split is by **signal origin, not preference**: Azure resource logs exist
only in Log Analytics and Prometheus cannot see them; pod metrics do not belong
in a per-GB log store. See [OBSERVABILITY.md](OBSERVABILITY.md).

---

## 6. Deployment and promotion path

```mermaid
flowchart TB
    DEV["Engineer"] --> PR["Pull request"]
    PR --> GATES{"CI gates"}
    GATES --> G1["terraform fmt · validate"]
    GATES --> G2["tflint"]
    GATES --> G3["trivy config — CRITICAL blocks"]
    GATES --> G4["cluster policy contract"]
    GATES --> G5["DAG import check"]
    GATES --> PLAN["terraform plan<br/>OIDC, read intent"]
    PLAN --> REV["Review"]
    REV --> MAIN["merge to main"]
    MAIN --> ENV{"Environment gate<br/>GitHub / ADO approval"}
    ENV --> Q["quota preflight"]
    Q --> A1["apply: envs/sandbox"]
    A1 --> A2["apply: envs/sandbox-databricks"]
    A2 --> HELM["deploy-platform.sh<br/>Airflow · Prometheus · Grafana"]

    style GATES stroke:#c5221f,stroke-width:2px
    style ENV stroke:#c5221f,stroke-width:2px
```

Order is enforced, not conventional: `sandbox-databricks` reads `sandbox`'s
outputs from remote state ([ADR-008](DECISIONS.md#adr-008)). Destroy reverses it.

---

## 7. Iconographic rendering

A rendering of this architecture using Azure service iconography — drawn in
Azure's visual language, laid out top-to-bottom across the six layers — is
published as a standalone page:

**[View the iconographic architecture](https://claude.ai/code/artifact/d7b717e1-acaf-4491-b4b2-2cf964fbf177)**

Source: [`architecture-visual.html`](architecture-visual.html) in this
directory. It is the version to use in a design review or a slide; the Mermaid
diagrams above are the version that stays correct in a pull request diff.

> **Icon provenance.** The published page uses SVG drawn to resemble the Azure
> service iconography, not Microsoft's official icon files. The official set is
> distributed by Microsoft under terms permitting use in architecture diagrams
> and can be substituted directly — each shape is a discrete `<symbol>` in the
> page source. Do not represent the drawn icons as Microsoft's own assets.

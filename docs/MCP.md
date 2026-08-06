# MCP servers

Model Context Protocol servers configured for this repository, and the reasoning
behind the selection. Configuration lives in [`.mcp.json`](../.mcp.json).

---

## Why only three

Every server's tools occupy context in **every** request, and overlapping
servers measurably degrade agent results — the model spends its attention
choosing between near-identical tools instead of doing the work. Three servers
is roughly 40–60 tools, which is a reasonable ceiling.

The temptation is to add everything available. Resist it: a server that is
useful once a month costs context on every request in between.

| Server | Reaches | Why it earns its place |
|---|---|---|
| `azure` | Azure control plane | Reading live platform state without shelling out to `az` repeatedly |
| `terraform` | Public registry only | Provider and module schema lookup — the most common source of the errors in [BUILD-LOG.md](BUILD-LOG.md) |
| `kubernetes` | Current kubeconfig context | Cluster state during an incident |

---

## The important safety property

**The `azure` server inherits your `az login` session, which on this
subscription is Owner.** There is no blanket read-only flag for it.

Two controls compensate:

1. **Namespace filtering.** `.mcp.json` loads only `group`, `storage`, `monitor`
   and `role` — the tool groups needed to *read* platform state. Namespaces that
   provision are not loaded, so those tools are not available to be called.
2. **A stated boundary.** [`CLAUDE.md`](../CLAUDE.md) instructs that
   infrastructure changes go through Terraform and a reviewed plan, never a tool
   call. This is a convention, not an enforcement — which is why control 1
   exists.

`kubernetes` is pinned with `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true`.
`terraform` touches no account at all and needs no credential.

**If you need to provision, write Terraform.** A tool call that creates a
resource produces infrastructure with no state entry, no review, and no record
of why it exists — which is the specific failure this repository is built to
avoid.

---

## Setup

```bash
export AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
az login          # the azure server uses this session
az aks get-credentials -g rg-yoda-sandbox-compute -n aks-yoda-sandbox   # kubernetes server
docker pull hashicorp/terraform-mcp-server:latest                       # terraform server
```

Claude Code picks `.mcp.json` up from the repository root. Confirm with:

```bash
claude mcp list
```

---

## Version notes

| Server | Package | Note |
|---|---|---|
| `azure` | `@azure/mcp@latest` | **Beta** (3.0.0-beta.x). Treat output as advisory; verify anything surprising with `az` directly |
| `terraform` | `hashicorp/terraform-mcp-server:latest` | Docker. Pin a tag if reproducibility matters more than currency |
| `kubernetes` | `mcp-server-kubernetes` | Acts on whichever kubeconfig context is current — check before asking about "the cluster" |

---

## Deliberately absent

| Server | Why not |
|---|---|
| A second Azure server | Overlapping tools are the specific pattern that degrades results |
| Databricks | The workspace API is reachable through the CLI with the same Entra token; a server would add tools for a narrow slice of the work |
| A diagram generator | Diagrams here are Mermaid and render natively in GitHub — a generator would produce artefacts nobody reviews in a diff |
| GitHub | `gh` is already on PATH and is enough for the operations this repository needs |

---

## When to reconsider

- **Databricks work becomes the majority of sessions** — a Databricks server
  starts paying for its context.
- **`@azure/mcp` reaches GA with a read-only mode** — the namespace workaround
  above can be replaced with a real control.
- **Any server is not used for a month** — remove it. An unused server is pure
  context cost.

## What this changes

<!-- One or two sentences. What is different after this merges? -->

## Why

<!-- The problem or need. If this is a design decision with a cost attached,
     it belongs in docs/DECISIONS.md as an ADR, not only here. -->

## Verification

<!-- Tick what you actually ran. `make check` runs all of them. -->

- [ ] `make check` passes locally
- [ ] `make plan ENV=sandbox` reviewed — **zero unexpected destroys**
- [ ] New/changed cost is stated below
- [ ] Docs updated (ADR, runbook, troubleshooting) if behaviour changed

## Cost impact

<!-- State the monthly figure, or "none". This platform runs against a finite
     credit where exceeding budget disables services — an unstated cost is a
     reliability risk, not just a financial one. -->

## Blast radius

<!-- What breaks if this is wrong, and how would you notice? -->

---

<sub>Terraform apply order is `sandbox` then `sandbox-databricks`; destroy
reverses it. Never commit `terraform.tfvars`, `backend.hcl` or state.</sub>

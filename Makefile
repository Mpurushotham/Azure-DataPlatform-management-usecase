# =============================================================================
# YODA Data Platform — automation entrypoint
# =============================================================================
# Everything CI does, a platform engineer can run locally with the same command.
# If a check only exists in the pipeline it gets discovered at PR time; if it
# only exists here it gets skipped. Both call these targets.
#
#   make help                  list targets
#   make check                 everything CI runs, in CI order
#   make quota                 preflight: will this environment even fit?
#   make bootstrap             remote state + OIDC federation (once per sub)
#   make plan ENV=sandbox      plan an environment
#   make apply ENV=sandbox     apply an environment
#   make stop / make start     park the cluster overnight, ~60% off the bill
# =============================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENV          ?= sandbox
TF_DIR       := terraform/envs/$(ENV)
REPO_ROOT    := $(shell git rev-parse --show-toplevel)
TFLINT_CFG   := $(REPO_ROOT)/.tflint.hcl
TRIVY_IGNORE := $(REPO_ROOT)/.trivyignore.yaml

# sandbox is the environment that actually exists on the subscription.
# prod is code-complete and deliberately never applied here — it carries the
# private endpoints, CMK, zone redundancy and Defender plans that a Free Trial
# subscription cannot fund. See docs/DECISIONS.md ADR-002.
# sandbox-databricks is a second root over the same environment, not a third
# environment. It shares sandbox's state container with its own key — see
# ADR-008 for why it is a separate root at all.
VALID_ENVS := sandbox sandbox-databricks prod

define check_env
	@if ! echo "$(VALID_ENVS)" | grep -qw "$(ENV)"; then \
		echo "ERROR: ENV must be one of: $(VALID_ENVS) (got '$(ENV)')"; exit 1; \
	fi
endef

define require
	@command -v $(1) >/dev/null 2>&1 || { \
		echo "ERROR: $(1) is not installed. See README.md prerequisites."; exit 1; }
endef

.PHONY: help
help: ## Show this help
	@echo "YODA Data Platform — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Set ENV=sandbox|prod (current: $(ENV))"

# ── Aggregate ────────────────────────────────────────────────────────────────
.PHONY: check
check: fmt-check lint validate scan policy-test dag-test docs-test ## Run every CI check locally
	@echo ""
	@echo "All checks passed."

# ── Terraform ────────────────────────────────────────────────────────────────
.PHONY: fmt
fmt: ## Format all Terraform
	$(call require,terraform)
	terraform fmt -recursive terraform/

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting
	$(call require,terraform)
	terraform fmt -check -recursive -diff terraform/

.PHONY: lint
lint: ## tflint across all modules and environments
	$(call require,tflint)
	@FAILED=0; \
	for dir in terraform/modules/*/ terraform/envs/*/ terraform/bootstrap/; do \
		echo "--- tflint $$dir"; \
		( cd "$$dir" && tflint --init --config="$(TFLINT_CFG)" >/dev/null \
		  && tflint --config="$(TFLINT_CFG)" --format compact ) || FAILED=1; \
	done; \
	exit $$FAILED

.PHONY: validate
validate: ## terraform validate across all roots
	$(call require,terraform)
	@FAILED=0; \
	for dir in terraform/modules/*/ terraform/envs/*/ terraform/bootstrap/; do \
		echo "--- validate $$dir"; \
		( cd "$$dir" && terraform init -backend=false -input=false >/dev/null \
		  && terraform validate ) || FAILED=1; \
	done; \
	exit $$FAILED

.PHONY: scan
scan: ## Trivy IaC scan (CRITICAL blocks, matching the CI gate)
	$(call require,trivy)
	trivy config terraform/ \
		--severity CRITICAL,HIGH \
		--ignorefile $(TRIVY_IGNORE) \
		--exit-code 1

.PHONY: init
init: ## terraform init against the remote backend for ENV
	$(call check_env)
	$(call require,terraform)
	@test -f $(TF_DIR)/backend.hcl || { \
		echo "ERROR: $(TF_DIR)/backend.hcl not found."; \
		echo "Generate it with: make backend-config ENV=$(ENV)"; exit 1; }
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl -reconfigure

.PHONY: plan
plan: ## terraform plan for ENV
	$(call check_env)
	$(call require,terraform)
	cd $(TF_DIR) && terraform plan -out=tfplan

.PHONY: apply
apply: ## terraform apply for ENV (prompts unless AUTO_APPROVE=1)
	$(call check_env)
	$(call require,terraform)
	@if [ "$(ENV)" = "prod" ] && [ "$${AUTO_APPROVE:-0}" = "1" ]; then \
		echo "ERROR: refusing AUTO_APPROVE against prod. Use the pipeline."; exit 1; \
	fi
	cd $(TF_DIR) && terraform apply $${AUTO_APPROVE:+-auto-approve} tfplan

.PHONY: destroy
destroy: ## terraform destroy for ENV (blocked for prod)
	$(call check_env)
	@if [ "$(ENV)" = "prod" ]; then \
		echo "ERROR: destroy is blocked for prod. Do it deliberately, not with make."; exit 1; \
	fi
	cd $(TF_DIR) && terraform destroy

.PHONY: output
output: ## Show terraform outputs for ENV
	$(call check_env)
	cd $(TF_DIR) && terraform output

.PHONY: bootstrap
bootstrap: ## Create remote state and OIDC federation (run once per subscription)
	$(call require,terraform)
	cd terraform/bootstrap && terraform init && terraform apply

.PHONY: backend-config
backend-config: ## Write backend.hcl for ENV from the bootstrap outputs
	$(call check_env)
	@cd terraform/bootstrap && \
		terraform output -json backend_config_hcl \
		| python3 -c "import json,sys;print(json.load(sys.stdin)['$(ENV)'])" \
		> "$(CURDIR)/$(TF_DIR)/backend.hcl"
	@echo "Wrote $(TF_DIR)/backend.hcl"

.PHONY: tfvars
tfvars: ## Generate envs/$(ENV)/terraform.tfvars from the current az login
	$(call check_env)
	$(call require,az)
	@SUB=$$(az account show --query id -o tsv); \
	TEN=$$(az account show --query tenantId -o tsv); \
	IP=$$(curl -s https://api.ipify.org); \
	MAIL=$$(az account show --query user.name -o tsv); \
	SUFFIX="yoda$$(echo $$SUB | cut -c1-4)"; \
	printf '%s\n' \
	  "# Generated by 'make tfvars ENV=$(ENV)'. Gitignored." \
	  "subscription_id = \"$$SUB\"" \
	  "tenant_id       = \"$$TEN\"" \
	  "unique_suffix   = \"$$SUFFIX\"" \
	  "" \
	  "# Default-deny ACLs and the AKS API server allow only this address." \
	  "operator_ip_ranges = [\"$$IP/32\"]" \
	  "" \
	  "budget_alert_emails = [\"$$MAIL\"]" \
	  > $(TF_DIR)/terraform.tfvars; \
	echo "Wrote $(TF_DIR)/terraform.tfvars (operator IP $$IP)"

# ── Policy and DAG tests (no Azure required) ─────────────────────────────────
.PHONY: policy-test
policy-test: ## Validate Databricks cluster policies and Azure Policy definitions
	@python3 scripts/python/validate_policies.py policies/

.PHONY: dag-test
dag-test: ## Import-check every Airflow DAG (catches syntax and cycle errors)
	@python3 scripts/python/validate_dags.py dags/

.PHONY: docs-test
docs-test: ## Verify every internal doc link and ADR anchor resolves
	@python3 scripts/python/check_docs.py

# ── Cluster ──────────────────────────────────────────────────────────────────
.PHONY: kubeconfig
kubeconfig: ## Fetch AKS credentials for ENV
	$(call check_env)
	$(call require,az)
	@RG=$$(cd $(TF_DIR) && terraform output -raw aks_resource_group); \
	NAME=$$(cd $(TF_DIR) && terraform output -raw aks_cluster_name); \
	az aks get-credentials --resource-group "$$RG" --name "$$NAME" --overwrite-existing

.PHONY: ui
ui: ## Open Airflow, Grafana and Prometheus locally (Ctrl-C to stop)
	@./scripts/bash/port-forward.sh

.PHONY: platform-deploy
platform-deploy: ## Install the in-cluster platform (Airflow, Prometheus, Grafana)
	$(call require,helm)
	./scripts/bash/deploy-platform.sh $(ENV)

# ── Cost control ─────────────────────────────────────────────────────────────
# The single biggest lever on a quota-constrained subscription is not running
# compute you are not using. `make stop` parks the AKS cluster; the control
# plane is Free tier so a stopped cluster bills only its managed disks.
.PHONY: stop
stop: ## Stop the AKS cluster (keeps state, stops node billing)
	$(call check_env)
	$(call require,az)
	@RG=$$(cd $(TF_DIR) && terraform output -raw aks_resource_group); \
	NAME=$$(cd $(TF_DIR) && terraform output -raw aks_cluster_name); \
	az aks stop --resource-group "$$RG" --name "$$NAME"

.PHONY: start
start: ## Start a stopped AKS cluster
	$(call check_env)
	$(call require,az)
	@RG=$$(cd $(TF_DIR) && terraform output -raw aks_resource_group); \
	NAME=$$(cd $(TF_DIR) && terraform output -raw aks_cluster_name); \
	az aks start --resource-group "$$RG" --name "$$NAME"

.PHONY: cost
cost: ## Month-to-date cost broken down by platform tag
	$(call require,az)
	@python3 scripts/python/finops_report.py --env $(ENV)

.PHONY: quota
quota: ## Preflight: vCPU quota vs what this environment needs
	$(call require,az)
	@./scripts/bash/check-quota.sh $(ENV)

.PHONY: scim-check
scim-check: ## Can Unity Catalog resolve the Entra groups? Run before enabling grants
	@./scripts/bash/setup-scim.sh --check

.PHONY: drift
drift: ## Detect Unity Catalog grant and tag drift against the declared state
	@python3 scripts/python/uc_drift.py --env $(ENV)

.PHONY: clean
clean: ## Remove local Terraform and render artefacts
	find terraform -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	find terraform -name 'tfplan' -delete 2>/dev/null || true
	rm -f /tmp/rendered.yaml
	@echo "Cleaned."

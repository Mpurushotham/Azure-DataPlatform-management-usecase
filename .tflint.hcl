# =============================================================================
# tflint — shared configuration for every Terraform root in this repo
# =============================================================================
# One config, referenced by both the Makefile and CI, so a lint failure is
# reproducible locally. A rule that only fires in the pipeline is a rule that
# gets discovered at PR time, which is the expensive place to discover it.
# =============================================================================

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Naming is a governance control here, not a style preference: the FinOps
# reports and the Azure Policy assignments both key off the resource name
# prefix, so an off-convention name silently drops out of cost attribution.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

# Modules are pinned by the caller, not by the module. Disabled because every
# module in this repo is local (./modules/...) and has no source to pin.
rule "terraform_module_pinned_source" {
  enabled = false
}

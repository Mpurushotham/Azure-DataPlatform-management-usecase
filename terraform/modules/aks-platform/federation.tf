# =============================================================================
# Workload identity federation
# =============================================================================
# The subject binds an Entra identity to exactly one Kubernetes ServiceAccount
# in one namespace:
#
#   system:serviceaccount:<namespace>:<service-account>
#
# That specificity is the control. A pod in another namespace, or the same
# namespace under a different ServiceAccount, cannot obtain the token — so
# compromising the Grafana pod does not yield Airflow's access to Databricks.
#
# Federation is declared here rather than in modules/identity because the
# issuer URL only exists once the cluster does.
# =============================================================================

resource "azurerm_federated_identity_credential" "workload" {
  for_each = var.workload_identities

  name                = "fic-aks-${each.key}"
  resource_group_name = each.value.identity_resource_group
  parent_id           = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${each.value.identity_resource_group}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${each.value.identity_name}"
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

data "azurerm_client_config" "current" {}

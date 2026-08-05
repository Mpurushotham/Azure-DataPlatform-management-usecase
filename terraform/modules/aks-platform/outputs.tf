output "cluster_id" {
  description = "AKS cluster resource ID."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "AKS cluster name, consumed by 'make kubeconfig'."
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "AKS-owned resource group holding the node VMSS and load balancers."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL, the trust anchor for every workload identity federated credential."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_client_id" {
  description = "Kubelet identity client ID, used by the Key Vault Secrets Provider."
  value       = azurerm_user_assigned_identity.kubelet.client_id
}

output "cluster_identity_principal_id" {
  description = "Control-plane identity object ID, for role assignments made outside this module."
  value       = azurerm_user_assigned_identity.cluster.principal_id
}

# =============================================================================
# AKS — the platform cluster, sized to what is left after Databricks
# =============================================================================
# This cluster does not process data. It orchestrates: Airflow schedules work,
# Databricks does it, and Prometheus and Grafana watch both. That distinction is
# what lets it run on 2 vCPU.
#
# Single untainted node pool, because 4 vCPU of quota cannot be split into a
# system pool and a user pool without one of them being too small to schedule
# anything. The production topology — separate system, memory and spot pools —
# is in envs/prod, and the module supports it; sandbox simply cannot fund it.
#
# Security posture, none of which is negotiable per environment:
#
#   local_account_disabled     no client certificate that outlives an employee
#   Entra RBAC                 group membership is the only path to the cluster
#   workload identity + OIDC   pods federate to Entra, no mounted secrets
#   Cilium NetworkPolicy       default-deny east-west, enforced in eBPF
# =============================================================================

locals {
  base_name    = "${var.name_prefix}-${var.environment}"
  cluster_name = "aks-${local.base_name}"

  tags = merge(var.tags, { component = "aks-platform" })
}

# Control plane identity. User-assigned rather than system-assigned so that the
# role assignment on the subnet can be made before the cluster exists — with a
# system-assigned identity that ordering is impossible and the first apply
# fails on a subnet it cannot join.
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "id-${local.base_name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-${local.base_name}-kubelet"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# The control plane identity must be able to join node NICs to the subnet and
# to act as the kubelet identity. Network Contributor scoped to the subnet, not
# the VNet: this cluster has no business reconfiguring the Databricks subnets.
resource "azurerm_role_assignment" "cluster_network" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

resource "azurerm_role_assignment" "cluster_kubelet_operator" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.enable_acr_pull ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id

  description = "Image pull for the custom Airflow image. Pull only — the cluster never pushes."
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  # AKS creates and owns this group: node VMSS, load balancers, node disks.
  # Named so it is recognisable in the bill.
  node_resource_group = "rg-${local.base_name}-aks-nodes"

  # No local admin kubeconfig. Every kubectl call is an Entra token belonging
  # to a person or a workload, which is the only way `kubectl` activity can be
  # attributed after the fact.
  local_account_disabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  # Pods federate to Entra for Azure access. This is what removes secrets from
  # the cluster entirely — Airflow reaches Databricks and ADLS with a projected
  # token, not a stored credential.
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  default_node_pool {
    name           = "system"
    vm_size        = var.node_vm_size
    vnet_subnet_id = var.subnet_id

    auto_scaling_enabled = true
    min_count            = var.node_count_min
    max_count            = var.node_count_max

    # Ephemeral OS disks are free of managed-disk charges and faster, but need
    # a VM size with enough cache. B-series has none, so this stays Managed —
    # an explicit choice rather than an oversight.
    os_disk_type    = "Managed"
    os_disk_size_gb = 64

    # Untainted. A CriticalAddonsOnly taint here would leave nowhere for
    # Airflow to run, because there is no second pool.
    only_critical_addons_enabled = false

    upgrade_settings {
      # One extra node during upgrade would exceed the vCPU quota and stall the
      # upgrade indefinitely. 10% rounds down to zero surge on a one-node pool,
      # which means the node is drained and replaced in place: brief downtime
      # for a platform that tolerates it, versus an upgrade that cannot run.
      max_surge = "10%"
    }

    tags = local.tags
  }

  network_profile {
    # Overlay: pods get addresses from pod_cidr, nodes from the VNet. A /16 of
    # pod space costs no VNet addresses at all, so scaling pod density never
    # threatens the subnet.
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    # The load balancer provides outbound. This is why the platform subnet
    # needs no NAT gateway — see modules/network/egress.tf.
    outbound_type     = "loadBalancer"
    load_balancer_sku = "standard"
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "5m"
  }

  # Container Insights ships pod-level logs and metrics to Log Analytics, which
  # the in-cluster Prometheus stack already collects. Enabled only when asked
  # for — and it cannot be declared with an empty workspace ID, which is why it
  # is a dynamic block rather than a nullable attribute.
  dynamic "oms_agent" {
    for_each = var.enable_container_insights ? [1] : []
    content {
      log_analytics_workspace_id      = var.log_analytics_workspace_id
      msi_auth_for_monitoring_enabled = true
    }
  }

  auto_scaler_profile {
    # Scale down slowly, scale up fast. A platform cluster that removes a node
    # ten minutes into a quiet period pays the cold-start cost on the next DAG;
    # the asymmetry costs a little idle capacity and buys predictable latency.
    scale_down_delay_after_add       = "15m"
    scale_down_unneeded              = "15m"
    scale_down_utilization_threshold = "0.4"
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      # AKS patches the node image continuously. Pinning it here would revert
      # the security patch on the next apply.
      default_node_pool[0].node_count,
      kubernetes_version,
    ]
  }
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-${local.cluster_name}"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # kube-audit-admin rather than kube-audit: the same write operations without
  # the get/list flood. On a 1 GB/day cap, full kube-audit is the single
  # noisiest source available and would exhaust the quota by itself.
  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-controller-manager"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

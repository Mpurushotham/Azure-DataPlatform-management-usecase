variable "name_prefix" {
  description = "Platform short name used in every resource name."
  type        = string
}

variable "environment" {
  description = "Environment name, part of every resource name and tag."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group holding the cluster. The node resource group is separate and AKS-owned."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for node NICs. Pod addresses come from the overlay CIDR, not from here."
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    AKS minor version. Pinned rather than latest — an unpinned control plane
    upgrades under you and the first you hear of it is a deprecated API.

    Must be on the KubernetesOfficial support plan. A version that has aged into
    AKSLongTermSupport is rejected at create time unless LTS is explicitly
    enabled on the cluster, and the error names the version rather than the
    support plan, which makes it read like the version does not exist:

      az aks get-versions --location <region> \
        --query "values[?capabilities.supportPlan[0]=='KubernetesOfficial'].version"
  EOT
  type        = string
  default     = "1.34"
}

variable "sku_tier" {
  description = <<-EOT
    Free or Standard.

    Free has no uptime SLA and caps at 1000 nodes, neither of which binds a
    single-node platform cluster. Standard costs about EUR 65/month for the
    control plane, which on this budget is the entire Databricks allowance.
  EOT
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "node_vm_size" {
  description = <<-EOT
    Node size. Standard_B2s_v2 is 2 vCPU and 8 GB.

    Burstable on purpose: the platform workload here is Airflow's scheduler and
    webserver plus Prometheus and Grafana, which idle most of the time and
    spike when a DAG runs. That is precisely the profile burstable credits are
    designed for, and it is half the price of the equivalent D-series.
  EOT
  type        = string
  default     = "Standard_B2s_v2"
}

variable "node_count_min" {
  description = "Autoscaler floor. One, because a stopped platform cluster is an acceptable state overnight and the scheduler recovers on start."
  type        = number
  default     = 1
}

variable "node_count_max" {
  description = <<-EOT
    Autoscaler ceiling.

    Two nodes at 2 vCPU each is 4 vCPU — the entire Sweden Central regional
    quota on this subscription. The ceiling is therefore not a preference, it
    is the quota. Raising it produces pods that stay Pending while the
    autoscaler retries a request Azure will keep refusing.
  EOT
  type        = number
  default     = 2
}

variable "pod_cidr" {
  description = "Overlay CIDR for pod addresses. Must not overlap the VNet — that is the whole point of overlay networking."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes service ClusterIPs. Must not overlap the VNet or the pod CIDR."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "Address of kube-dns inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "api_server_authorized_ip_ranges" {
  description = <<-EOT
    Source addresses allowed to reach the Kubernetes API server.

    Deliberately has no default and may not be empty. An empty list does not
    mean "no access" — it means the API server answers the entire internet,
    which is the opposite of what an unset variable reads like. Making it
    required moves that decision from an omission to a choice.

    Entra RBAC and local_account_disabled still stand behind it, so an exposed
    API server is not an open one. It is, however, an authentication endpoint
    on the public internet, and there is no reason for this platform to have
    one.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0
    error_message = "api_server_authorized_ip_ranges must not be empty. Use 'make tfvars ENV=<env>' to populate it from your current public IP, or pass the office/VPN egress ranges. This module does not support a private API server; that would be a different topology."
  }
}

variable "admin_group_object_ids" {
  description = "Entra group object IDs granted cluster-admin through Kubernetes RBAC. There is no local admin account to fall back on."
  type        = list(string)
  default     = []
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace for control-plane diagnostics. Empty disables the diagnostic setting."
  type        = string
  default     = ""
}

variable "enable_container_insights" {
  description = <<-EOT
    Azure Monitor Container Insights.

    Off by default: it duplicates what the in-cluster Prometheus stack already
    collects, and it is billed per GB ingested against a 1 GB/day cap that the
    Databricks audit logs need. Kept as a switch because it is the right answer
    on a cluster without its own Prometheus.
  EOT
  type        = bool
  default     = false
}

variable "acr_id" {
  description = "Container registry the kubelet identity is granted AcrPull on. Empty skips the assignment."
  type        = string
  default     = ""
}

variable "enable_acr_pull" {
  description = "Grant the kubelet identity AcrPull on acr_id. Separate from acr_id being non-empty because that ID comes from another module and is unknown at plan time."
  type        = bool
  default     = false
}

variable "workload_identities" {
  description = <<-EOT
    Workloads that federate into an Entra managed identity, keyed by a short
    name. Each entry needs the identity's resource group and name plus the
    namespace and ServiceAccount it is bound to. See federation.tf for why the
    subject is scoped this tightly.
  EOT
  type = map(object({
    identity_resource_group = string
    identity_name           = string
    namespace               = string
    service_account         = string
  }))
  default = {}
}

variable "enable_diagnostics" {
  description = "Whether to create diagnostic settings. A plan-time boolean rather than a test on log_analytics_workspace_id, which is produced by another module and unknown at plan time — and `count` cannot depend on an unknown."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "name_prefix" {
  description = "Platform short name used in policy and warehouse names."
  type        = string
}

variable "environment" {
  description = "Environment name, part of every object name and every enforced tag."
  type        = string
}

variable "domain" {
  description = "Data domain this compute belongs to. Enforced as a cluster tag so DBU spend is attributable."
  type        = string
}

variable "cost_center" {
  description = "Cost centre enforced as a fixed cluster tag."
  type        = string
  default     = "data-platform"
}

variable "max_autotermination_minutes" {
  description = <<-EOT
    Ceiling on cluster idle time before automatic termination.

    Thirty minutes, not sixty. An idle interactive cluster is the single
    largest avoidable line on a Databricks bill, and the difference between the
    two settings across a team of ten is thousands of DBU per month spent on
    nothing. Users may set a lower value, never a higher one.
  EOT
  type        = number
  default     = 30
}

variable "max_workers_limit" {
  description = "Hard ceiling on autoscale workers. Stops a runaway job from consuming the regional quota and starving every other workload."
  type        = number
  default     = 4
}

variable "allowed_node_types" {
  description = <<-EOT
    Node types users may select.

    Constrained to a small set on purpose: an allowlist is the only cluster
    policy control that prevents someone selecting a memory-optimised
    forty-eight-core node for a job that reads a CSV.
  EOT
  type        = list(string)
  default     = ["Standard_D4ads_v5", "Standard_D8ads_v5"]
}

variable "default_node_type" {
  description = "Node type pre-selected in the cluster UI. Must appear in allowed_node_types."
  type        = string
  default     = "Standard_D4ads_v5"

}

variable "spark_version" {
  description = "Databricks Runtime version. An LTS release — a platform that tracks the newest runtime spends its time debugging the newest runtime."
  type        = string
  default     = "15.4.x-scala2.12"
}

variable "enable_sql_warehouse" {
  description = "Create the serverless SQL warehouse. It costs nothing while stopped and bills DBU per second while a query runs."
  type        = bool
  default     = true
}

variable "sql_warehouse_size" {
  description = "Warehouse t-shirt size. 2X-Small is the floor and is ample for validation queries and dashboard development."
  type        = string
  default     = "2X-Small"
}

variable "sql_warehouse_auto_stop_minutes" {
  description = "Idle minutes before the warehouse stops. Ten is the practical floor — lower and an analyst pays the cold-start penalty between queries."
  type        = number
  default     = 10
}

output "interactive_policy_id" {
  description = "Cluster policy ID for interactive clusters, referenced when granting CAN_USE to a domain group."
  value       = databricks_cluster_policy.interactive.id
}

output "job_policy_id" {
  description = "Cluster policy ID for job clusters. Airflow's DatabricksSubmitRunOperator references this so scheduled work inherits the spot and tagging rules."
  value       = databricks_cluster_policy.job.id
}

output "sql_warehouse_id" {
  description = "Serverless SQL warehouse ID. Empty when the warehouse is disabled."
  value       = var.enable_sql_warehouse ? databricks_sql_endpoint.this[0].id : ""
}

output "sql_warehouse_jdbc_url" {
  description = "JDBC connection string for the warehouse, used by Grafana's Databricks datasource and by BI tools."
  value       = var.enable_sql_warehouse ? databricks_sql_endpoint.this[0].jdbc_url : ""
}

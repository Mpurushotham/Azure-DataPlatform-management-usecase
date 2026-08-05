output "catalogs" {
  description = "Unity Catalog catalog name per domain."
  value = {
    platform  = module.uc_central.catalog_name
    logistics = module.uc_logistics.catalog_name
  }
}

output "schemas" {
  description = "Fully-qualified schema names per domain and layer."
  value = {
    platform  = module.uc_central.schema_names
    logistics = module.uc_logistics.schema_names
  }
}

output "cluster_policy_ids" {
  description = "Cluster policy IDs per domain. The job policy is referenced by the Airflow DatabricksSubmitRunOperator so scheduled work inherits the spot and tagging rules."
  value = {
    platform = {
      interactive = module.compute_central.interactive_policy_id
      job         = module.compute_central.job_policy_id
    }
    logistics = {
      interactive = module.compute_logistics.interactive_policy_id
      job         = module.compute_logistics.job_policy_id
    }
  }
}

output "sql_warehouse_ids" {
  description = "Serverless SQL warehouse IDs per domain."
  value = {
    platform  = module.compute_central.sql_warehouse_id
    logistics = module.compute_logistics.sql_warehouse_id
  }
}

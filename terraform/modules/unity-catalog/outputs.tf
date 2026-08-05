output "catalog_name" {
  description = "Unity Catalog catalog name for this domain, referenced by jobs and by the Airflow DAGs."
  value       = databricks_catalog.this.name
}

output "schema_names" {
  description = "Fully-qualified schema names keyed by layer."
  value       = { for k, s in databricks_schema.this : k => "${databricks_catalog.this.name}.${s.name}" }
}

output "storage_credential_name" {
  description = "Name of the storage credential wrapping the Access Connector identity."
  value       = databricks_storage_credential.this.name
}

output "external_location_urls" {
  description = "Registered external location URLs keyed by layer. A path absent here is unreachable from Unity Catalog."
  value       = { for k, e in databricks_external_location.this : k => e.url }
}

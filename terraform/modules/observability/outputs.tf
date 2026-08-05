output "workspace_id" {
  description = "Log Analytics workspace resource ID, consumed by every diagnostic setting on the platform."
  value       = azurerm_log_analytics_workspace.this.id
}

output "workspace_customer_id" {
  description = "Workspace GUID, used by in-cluster agents and by Grafana's Azure Monitor datasource."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.this.name
}

output "action_group_page_id" {
  description = "Action group for severity 1 alerts that page."
  value       = azurerm_monitor_action_group.page.id
}

output "action_group_ticket_id" {
  description = "Action group for severity 2 and 3 alerts that raise a ticket. Also used by budget alerts."
  value       = azurerm_monitor_action_group.ticket.id
}

output "uptime_check_ids" {
  description = "Uptime check IDs, keyed by endpoint name."
  value       = { for k, v in google_monitoring_uptime_check_config.public : k => v.uptime_check_id }
}

output "monitored_hosts" {
  description = "Hostnames probed by this stack."
  value       = { for k, v in var.monitored_endpoints : k => v.host }
}

output "notification_channel_ids" {
  description = "Notification channels wired to every alert policy in this stack."
  value       = [for c in google_monitoring_notification_channel.email : c.id]
}

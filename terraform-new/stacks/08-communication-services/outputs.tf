# Communication Services Stack - Outputs

output "service_account_email" {
  description = "Communication services service account email"
  value       = var.enable_communication_services ? google_service_account.communication_services[0].email : null
}

output "email_topic_id" {
  description = "Email queue Pub/Sub topic ID"
  value       = var.enable_communication_services && var.enable_pubsub_queues ? google_pubsub_topic.email_queue[0].id : null
}

output "sms_topic_id" {
  description = "SMS queue Pub/Sub topic ID"
  value       = var.enable_communication_services && var.enable_pubsub_queues ? google_pubsub_topic.sms_queue[0].id : null
}

output "push_topic_id" {
  description = "Push queue Pub/Sub topic ID"
  value       = var.enable_communication_services && var.enable_pubsub_queues ? google_pubsub_topic.push_queue[0].id : null
}

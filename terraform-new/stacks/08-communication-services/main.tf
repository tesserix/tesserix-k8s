# Communication Services Stack - Email, SMS, Push Notifications
# State: stacks/prod/communication-services/default.tfstate
# Dependencies: 01-foundation

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/foundation"
  }
}

# =============================================================================
# Enable Required APIs
# =============================================================================

resource "google_project_service" "communication_apis" {
  for_each = var.enable_communication_services ? toset([
    "pubsub.googleapis.com",
    "firebase.googleapis.com",
  ]) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# =============================================================================
# Service Account for Communication Services
# =============================================================================

resource "google_service_account" "communication_services" {
  count = var.enable_communication_services ? 1 : 0

  account_id   = "${var.environment}-communication-svc"
  display_name = "Communication Services"
  description  = "Service account for email, SMS, and push notification services"
  project      = var.project_id
}

resource "google_project_iam_member" "communication_services_roles" {
  for_each = var.enable_communication_services ? toset([
    "roles/pubsub.publisher",
    "roles/pubsub.subscriber",
  ]) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.communication_services[0].email}"
}

# =============================================================================
# Pub/Sub Topics for Async Processing
# =============================================================================

resource "google_pubsub_topic" "email_queue" {
  count   = var.enable_communication_services && var.enable_pubsub_queues ? 1 : 0
  name    = "${var.environment}-email-queue"
  project = var.project_id

  labels = var.common_labels

  depends_on = [google_project_service.communication_apis]
}

resource "google_pubsub_topic" "sms_queue" {
  count   = var.enable_communication_services && var.enable_pubsub_queues ? 1 : 0
  name    = "${var.environment}-sms-queue"
  project = var.project_id

  labels = var.common_labels

  depends_on = [google_project_service.communication_apis]
}

resource "google_pubsub_topic" "push_queue" {
  count   = var.enable_communication_services && var.enable_pubsub_queues ? 1 : 0
  name    = "${var.environment}-push-queue"
  project = var.project_id

  labels = var.common_labels

  depends_on = [google_project_service.communication_apis]
}

# =============================================================================
# Pub/Sub Subscriptions
# =============================================================================

resource "google_pubsub_subscription" "email_processor" {
  count   = var.enable_communication_services && var.enable_pubsub_queues ? 1 : 0
  name    = "${var.environment}-email-processor"
  topic   = google_pubsub_topic.email_queue[0].name
  project = var.project_id

  ack_deadline_seconds = 60

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  labels = var.common_labels
}

resource "google_pubsub_subscription" "sms_processor" {
  count   = var.enable_communication_services && var.enable_pubsub_queues ? 1 : 0
  name    = "${var.environment}-sms-processor"
  topic   = google_pubsub_topic.sms_queue[0].name
  project = var.project_id

  ack_deadline_seconds = 60

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  labels = var.common_labels
}

resource "google_pubsub_subscription" "push_processor" {
  count   = var.enable_communication_services && var.enable_pubsub_queues ? 1 : 0
  name    = "${var.environment}-push-processor"
  topic   = google_pubsub_topic.push_queue[0].name
  project = var.project_id

  ack_deadline_seconds = 60

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  labels = var.common_labels
}

# =============================================================================
# Event Topics — Platform + Marketplace
# =============================================================================
# Created for services that publish domain events via go-shared/messaging.
# Services use GCP_PROJECT_ID + PUBSUB_TOPIC env vars to publish.
# =============================================================================

locals {
  event_labels = {
    managed_by  = "terraform"
    environment = var.environment
    component   = "events"
  }

  platform_topics = {
    "tesserix-audit-events"        = "Audit trail events from auth-bff and platform services"
    "tesserix-settings-events"     = "Settings change events from settings-service"
    "tesserix-subscription-events" = "Subscription lifecycle events from subscription-service"
    "tesserix-ticket-events"       = "Ticket CRUD events from tickets-service"
    "tesserix-notification-events" = "Notification dispatch events from verification-service"
  }

  marketplace_topics = {
    "mp-product-events"   = "Product CRUD events from mp-products"
    "mp-order-events"     = "Order lifecycle events from mp-orders"
    "mp-payment-events"   = "Payment processing events from mp-payments"
    "mp-inventory-events" = "Inventory change events from mp-inventory"
    "mp-staff-events"     = "Staff management events from mp-staff"
    "mp-approval-events"  = "Approval workflow events from mp-approvals"
    "mp-gift-card-events" = "Gift card lifecycle events from mp-gift-cards"
    "mp-marketing-events" = "Marketing campaign events from mp-marketing"
    "mp-tax-events"       = "Tax calculation events from mp-tax"
  }

  all_event_topics = merge(local.platform_topics, local.marketplace_topics)
}

resource "google_pubsub_topic" "event_topics" {
  for_each = var.enable_communication_services ? local.all_event_topics : {}

  name    = each.key
  project = var.project_id

  labels = merge(local.event_labels, {
    topic = replace(each.key, "-", "_")
  })

  message_retention_duration = "604800s" # 7 days

  depends_on = [google_project_service.communication_apis]
}

resource "google_pubsub_topic" "event_dlq" {
  for_each = var.enable_communication_services ? local.all_event_topics : {}

  name    = "${each.key}-dlq"
  project = var.project_id

  labels = merge(local.event_labels, {
    topic = "${replace(each.key, "-", "_")}_dlq"
  })

  message_retention_duration = "1209600s" # 14 days

  depends_on = [google_project_service.communication_apis]
}

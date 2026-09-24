# Uptime Monitoring Stack Variables

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "asia-south1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

# =============================================================================
# Who gets told
# =============================================================================
# EXISTING Cloud Monitoring notification channel IDs, in the full form
# "projects/<project>/notificationChannels/<id>".
#
# This stack REFERENCES channels rather than creating them, so no Slack token
# or personal email address is committed to this repository.
#
# The estate's alert destination is Slack #falco-events, reached today by
# Alertmanager posting to the incoming webhook in Secret Manager
# (prod-falco-slack-webhook). GCP CANNOT REUSE THAT URL: a Slack incoming
# webhook accepts only {"text": ...} or Block Kit, while a Cloud Monitoring
# webhook channel posts its own incident JSON, which Slack rejects with
# invalid_payload. Wiring it that way yields a channel that reads as
# configured and delivers nothing — the precise failure this stack exists to
# end.
#
# So the Slack channel must be created once in Cloud Monitoring (Alerting ->
# Notification channels -> Slack -> authorize the Google Cloud Monitoring app
# against #falco-events), after which its ID goes here and terraform manages
# the wiring from then on.
#
# REQUIRED, with no default, deliberately: an alert policy with no channel
# renders green, satisfies a review, and tells nobody. The estate already had
# one of those — a ServiceMonitor scraping the Cloudflare tunnel for 228 days
# with no rule reading it — and this stack exists because of it. A failing
# plan until somebody names a recipient is the point.
variable "alert_notification_channels" {
  description = "Existing Cloud Monitoring notification channel IDs to notify on outage. Must not be empty."
  type        = list(string)

  validation {
    condition     = length(var.alert_notification_channels) > 0
    error_message = "alert_notification_channels must contain at least one channel, or these alerts notify nobody."
  }

  validation {
    condition     = alltrue([for c in var.alert_notification_channels : can(regex("^projects/[^/]+/notificationChannels/[0-9]+$", c))])
    error_message = "Each channel must be a full ID like projects/<project>/notificationChannels/<numeric-id>."
  }
}

# =============================================================================
# What is watched
# =============================================================================
# Keyed by a short stable name so adding a host does not renumber the others
# in state. `expected_status_class` exists because not every public entry
# point answers 2xx: console.tesserix.app answers 307 to its login flow and
# helivanta.app answers 307, and an uptime check that demanded 2xx would page
# permanently for a service that is working perfectly.
variable "monitored_endpoints" {
  description = "Public hostnames probed from outside the estate."
  type = map(object({
    host : string
    path : optional(string, "/")
    expected_status_class : optional(string, "STATUS_CLASS_2XX")
  }))

  default = {
    tesserix-app = {
      host = "tesserix.app"
    }
    console = {
      host                  = "console.tesserix.app"
      expected_status_class = "STATUS_CLASS_3XX"
    }
    mark8ly = {
      host = "mark8ly.com"
    }
    fe3dr = {
      host = "fe3dr.com"
    }
    helivanta = {
      host                  = "helivanta.app"
      expected_status_class = "STATUS_CLASS_3XX"
    }
    # The Zitadel IdP. Added after the 2026-09-24 Cloudflare APAC incident,
    # during which auth.tesserix.app served the login UI as a blank page with
    # 10-90s stalls and intermittent 520/525 for anyone entering at an affected
    # edge, and NOTHING alerted -- this stack was the thing that should have,
    # and it was not watching this host.
    #
    # Probes the OIDC discovery document rather than "/", which answers 302.
    # That is deliberate beyond avoiding a 3XX class: discovery requires
    # Zitadel to resolve the instance from its database, so a 200 here means
    # the IdP is genuinely serving, whereas a 302 on "/" can be produced by
    # Istio alone while Zitadel is down. Measured 200 in 91ms from inside the
    # cluster on 2026-09-24.
    auth = {
      host = "auth.tesserix.app"
      path = "/.well-known/openid-configuration"
    }
  }
}

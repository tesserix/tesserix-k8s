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
# REQUIRED, with no default, and that is deliberate.
#
# An alert policy with no notification channel is worse than no alert policy:
# it renders green in the console, satisfies a review, and tells nobody. The
# estate already has one instance of that shape — a ServiceMonitor scraping
# the Cloudflare tunnel for 228 days with no rule reading it — and this stack
# exists because of it. `terraform apply` failing until somebody names a
# recipient is the point.
#
# Supply via tfvars (which is gitignored) rather than a default here, so no
# personal address is committed to this repository.
variable "alert_emails" {
  description = "Email addresses notified when a public endpoint goes down. Must not be empty."
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "alert_emails must contain at least one address, or these alerts notify nobody."
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
  }
}

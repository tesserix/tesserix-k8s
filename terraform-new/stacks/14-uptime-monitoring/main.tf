# =============================================================================
# External uptime monitoring for the public estate
# =============================================================================
# WHY THIS EXISTS, MEASURED RATHER THAN ASSUMED.
#
# On 2026-09-21 tesserix.app, console.tesserix.app, mark8ly.com, fe3dr.com and
# helivanta.app failed intermittently for Australian users over several hours.
# Nothing detected it. Every monitor the estate had was looking in the wrong
# place:
#
#   - `company-uptime-probe` (charts/apps/company) probes
#     http://company.<ns>/api/internal/uptime/probe — an in-cluster ClusterIP
#     over plain HTTP. It never touches Cloudflare, the tunnel, or the ingress
#     gateway, so it CANNOT observe this failure. It ran every 5 minutes
#     throughout and stayed green.
#   - The tunnel's own metrics were healthy and honest:
#     cloudflared_tunnel_ha_connections held at 4, request_errors showed zero
#     increase over 8 hours, up never dropped. The requests died at
#     Cloudflare's edge and never reached the tunnel.
#
# Measured at the time, all five hosts answered correctly from inside the
# cluster and from a pod in asia-south1 (30/30, 0.16s) while three of six were
# unreachable from Australia. An origin-side check of any kind — in-cluster,
# in-region, or on the tunnel — is structurally blind to that.
#
# So the check has to run from OUTSIDE, from more than one place. GCP uptime
# checks run from multiple global regions (Americas, Europe, Asia-Pacific) and
# report per-region, which turns "some users cannot reach us" from an
# unfalsifiable support ticket into a graph.
#
# WHY NOT CLOUDFLARE HEALTH CHECKS, which would be the closer vantage point:
# every zone on this account is on the Free plan (verified 2026-09-21 via the
# zones API) and standalone Health Checks need Pro or above.
#
# COST: the free tier covers 1M check executions per month. This stack does NOT
# use the 5-minute default — see `period` below, set to 60s so an intermittent
# failure is not sampled past. Six endpoints at 60s across every probe region
# is roughly 1.56M executions/month, OVER the free allotment. That is
# accepted deliberately: the cadence is what makes the check able to see the
# failure it exists for, and an earlier draft of this comment quoted the
# 5-minute figure while the resource ran at 60s, which would have been read
# back as "this is free" for as long as nobody checked the bill.
# =============================================================================

locals {
  common_labels = {
    environment = var.environment
    managed_by  = "terraform"
    stack       = "uptime-monitoring"
  }
}

# =============================================================================
# The checks
# =============================================================================
resource "google_monitoring_uptime_check_config" "public" {
  for_each = var.monitored_endpoints

  project      = var.project_id
  display_name = "public-${each.key}"

  # 60s is the shortest GCP offers and the difference matters here: the
  # 2026-09-21 failure was intermittent (roughly a third of requests), so a
  # slow cadence would have sampled its way past it. At six endpoints this
  # is still far inside the free tier.
  period  = "60s"
  timeout = "10s"

  http_check {
    # HTTPS through Cloudflare, exactly as a browser reaches it. Not the
    # origin, not the LoadBalancer, not a ClusterIP — the whole path,
    # including the leg that actually broke.
    use_ssl        = true
    path           = each.value.path
    port           = 443
    request_method = "GET"

    # An endpoint that answers 307 to its login flow is UP. Demanding 2xx
    # everywhere would page forever for console.tesserix.app and
    # helivanta.app, and an alert that is always firing is an alert nobody
    # reads.
    accepted_response_status_codes {
      status_class = each.value.expected_status_class
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = each.value.host
    }
  }

  # Left at the provider default, which is every available region. Narrowing
  # it would reintroduce exactly the blind spot this stack exists to remove:
  # the estate looked healthy from asia-south1 while Australia could not
  # reach it. Breadth of vantage point IS the feature.
  checker_type = "STATIC_IP_CHECKERS"
}

# =============================================================================
# Alerting
# =============================================================================
# One policy per endpoint rather than one policy matching all of them, so the
# notification names the host that is down. A single combined policy would
# fire "a public endpoint is unreachable" and leave the responder to work out
# which of five — at the point where minutes matter.
resource "google_monitoring_alert_policy" "endpoint_down" {
  for_each = var.monitored_endpoints

  project      = var.project_id
  display_name = "Public endpoint down — ${each.value.host}"
  combiner     = "OR"

  conditions {
    display_name = "${each.value.host} failing uptime checks"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
        "resource.type=\"uptime_url\"",
        "metric.label.check_id=\"${google_monitoring_uptime_check_config.public[each.key].uptime_check_id}\"",
      ])

      # count_true over a 5-minute window, per checker region, then alert
      # when the number of regions still succeeding falls below 2.
      #
      # NOT "any region failed": a single region blipping is normal
      # background noise on the public internet and would page constantly.
      # NOT "all regions failed" either — that is the bar that made the
      # 2026-09-21 outage invisible, because the endpoints genuinely were
      # reachable from most of the world while Australian users could not
      # load them. Two independent regions failing is the smallest signal
      # that means something real is wrong for a population of users.
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_TRUE"
        group_by_fields      = ["resource.label.host"]
      }

      comparison      = "COMPARISON_LT"
      threshold_value = 2
      duration        = "300s"

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.alert_notification_channels

  alert_strategy {
    # Auto-close well after a real incident would be noticed, so a flapping
    # endpoint does not generate a new alert every cycle.
    auto_close = "1800s"
  }

  documentation {
    subject   = "${each.value.host} is unreachable from multiple regions"
    content   = <<-EOT
      ${each.value.host} has failed its external uptime check from two or more
      GCP probe regions for 5 minutes.

      FIRST, ESTABLISH WHERE THE BREAK IS. These three answers mean different
      things and the wrong assumption costs an hour:

      1. From inside the cluster (bypasses Cloudflare entirely):
           kubectl port-forward -n istio-ingress svc/istio-ingressgateway 18080:80
           curl -H "Host: ${each.value.host}" http://127.0.0.1:18080/
         Fails  -> the app or Istio routing. Look at the workload.
         Works  -> the cluster is fine; keep going.

      2. The tunnel every public hostname depends on:
           kubectl get pods -n cloudflared
           kubectl logs -n cloudflared deploy/cloudflared --since=30m
         Look for "Unable to reach the origin service" and "Lost connection
         with the edge". The alerts in
         k8s/cluster/prometheus/rules/cloudflared.yaml cover this case.

      3. If 1 and 2 are both healthy, the break is at Cloudflare's edge or on
         the path to it, and it will be REGIONAL. Check which probe regions
         failed in the uptime dashboard. Note that all tunnel connections
         terminate in Mumbai, so traffic entering far from there crosses
         Cloudflare's backbone to reach the origin — that leg is what failed
         on 2026-09-21, and no cluster-side metric can see it.

      Do not trust company-uptime-probe for this: it probes a ClusterIP over
      plain HTTP and is green during an edge outage by construction.
    EOT
    mime_type = "text/markdown"
  }

  user_labels = local.common_labels
}

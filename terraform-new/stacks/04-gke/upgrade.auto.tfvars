# Reviewed non-preview Rapid version. Node rollouts use the gated workflow.
control_plane_version = "1.37.0-gke.3503000"

# Does not cancel an active operation. Remove after node verification.
node_upgrade_hold = {
  name       = "ax-control-plane-first-20261002"
  start_time = "2026-10-02T00:00:00Z"
  end_time   = "2026-10-09T00:00:00Z"
}

mock_provider "google" {
  mock_data "google_container_engine_versions" {
    defaults = {
      latest_master_version = "1.36.4-gke.1495000"
      latest_node_version   = "1.36.4-gke.1495000"
    }
  }

  mock_resource "google_container_node_pool" {
    defaults = {
      version = "1.36.3-gke.1767000"
    }
  }
}

mock_provider "google-beta" {}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      vpc_name               = "test-vpc"
      subnet_name            = "test-subnet"
      pods_ip_range_name     = "pods"
      services_ip_range_name = "services"
    }
  }
}

variables {
  project_id            = "test-project"
  region                = "asia-south1"
  control_plane_version = "1.37.0-gke.3503000"
}

run "control_plane_uses_reviewed_exact_version" {
  command = plan

  assert {
    condition     = google_container_cluster.primary.min_master_version == "1.37.0-gke.3503000"
    error_message = "The control plane must use the reviewed version, not a moving latest lookup."
  }
}

run "automatic_node_upgrades_are_held_during_staged_upgrade" {
  command = plan

  variables {
    node_upgrade_hold = {
      name       = "staged-upgrade"
      start_time = "2026-10-02T00:00:00Z"
      end_time   = "2026-10-09T00:00:00Z"
    }
  }

  assert {
    condition = anytrue([
      for exclusion in google_container_cluster.primary.maintenance_policy[0].maintenance_exclusion :
      exclusion.exclusion_name == "staged-upgrade" &&
      exclusion.end_time == "2026-10-09T00:00:00Z" &&
      exclusion.exclusion_options[0].scope == "NO_MINOR_OR_NODE_UPGRADES"
    ])
    error_message = "A staged control-plane upgrade must preserve its bounded automatic node-upgrade hold."
  }
}

run "seed_existing_node_version" {
  command = apply

  variables {
    control_plane_version = "1.36.3-gke.1767000"
  }
}

run "control_plane_upgrade_preserves_existing_nodes" {
  command = plan

  assert {
    condition     = google_container_node_pool.pools["default-pool"].version == "1.36.3-gke.1767000"
    error_message = "A control-plane upgrade must not schedule a node rollout."
  }

  assert {
    condition     = google_container_cluster.primary.deletion_protection
    error_message = "Cluster deletion protection must remain enabled."
  }
}

run "reject_latest" {
  command = plan
  variables {
    control_plane_version = "latest"
  }
  expect_failures = [var.control_plane_version]
}

run "reject_preview" {
  command = plan
  variables {
    control_plane_version = "1.38.0-gke.1002000+preview"
  }
  expect_failures = [var.control_plane_version]
}

run "reject_unbounded_node_hold" {
  command = plan
  variables {
    node_upgrade_hold = {
      name       = "too-long"
      start_time = "2026-10-02T00:00:00Z"
      end_time   = "2026-12-02T00:00:00Z"
    }
  }
  expect_failures = [var.node_upgrade_hold]
}

run "headroom_only_changes_selected_pool_total_limit" {
  command = plan
  variables {
    node_pools = [
      { name = "default-pool", min_count = null, max_count = null, total_min_count = 3, total_max_count = 7 },
      { name = "gpu", min_count = 0, max_count = 1 }
    ]
    node_pool_total_max_count_overrides = { "default-pool" = 10 }
  }
  assert {
    condition     = google_container_node_pool.pools["default-pool"].autoscaling[0].total_max_node_count == 10 && google_container_node_pool.pools["default-pool"].autoscaling[0].total_min_node_count == 3
    error_message = "Headroom must raise only the total ceiling, not the minimum."
  }
  assert {
    condition     = google_container_node_pool.pools["gpu"].autoscaling[0].max_node_count == 1
    error_message = "Other pools must retain their existing limits."
  }
}

run "reject_ceiling_below_configured_total" {
  command = plan
  variables {
    node_pools                          = [{ name = "default-pool", min_count = null, max_count = null, total_min_count = 3, total_max_count = 7 }]
    node_pool_total_max_count_overrides = { "default-pool" = 6 }
  }
  expect_failures = [google_container_node_pool.pools["default-pool"]]
}

run "reject_unknown_pool_ceiling" {
  command = plan
  variables {
    node_pool_total_max_count_overrides = { missing = 10 }
  }
  expect_failures = [google_container_node_pool.pools["default-pool"]]
}

run "reject_fractional_ceiling" {
  command = plan
  variables {
    node_pool_total_max_count_overrides = { "default-pool" = 9.5 }
  }
  expect_failures = [var.node_pool_total_max_count_overrides]
}

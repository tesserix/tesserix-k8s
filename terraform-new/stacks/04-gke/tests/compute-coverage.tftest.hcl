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

run "production_seven_nodes_match_existing_cuds" {
  command = plan
  variables {
    project_id = "tesseracthub-480811"
    node_pools = [{ name = "optimized-v2", machine_type = "e2-standard-8", min_count = null, max_count = null, total_min_count = 3, total_max_count = 6 }]
  }
  assert {
    condition     = sum([for c in local.e2_commitments : lookup(c.resources, "VCPU", 0)]) == 56 && sum([for c in local.e2_commitments : lookup(c.resources, "MEMORY", 0)]) == 229376
    error_message = "Existing purchases must represent 56 vCPU and 224 GiB, not new commitments."
  }
}

run "reject_uncovered_production_eighth_node" {
  command = plan
  variables {
    project_id = "tesseracthub-480811"
    node_pools = [{ name = "optimized-v2", machine_type = "e2-standard-8", min_count = null, max_count = null, total_min_count = 3, total_max_count = 7 }]
  }
  expect_failures = [google_container_node_pool.general]
}

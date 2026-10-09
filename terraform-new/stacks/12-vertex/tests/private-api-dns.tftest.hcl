mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id = "test-project"
  region     = "asia-south1"
}

run "migrate_dns_before_retiring_psc" {
  command = plan

  variables {
    enable_vertex_psc = true
  }

  assert {
    condition     = google_dns_record_set.vertex_apex.rrdatas == tolist(["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"])
    error_message = "Vertex apex must use the validated private Google API VIPs."
  }

  assert {
    condition     = length(google_compute_global_forwarding_rule.vertex_psc) == 1 && length(google_compute_global_address.vertex_psc_ip) == 1
    error_message = "Keep PSC allocated until DNS clients have migrated."
  }

  assert {
    condition     = google_dns_record_set.vertex_wildcard.rrdatas == google_dns_record_set.vertex_apex.rrdatas
    error_message = "Wildcard Vertex hosts must use the same private routing."
  }
}

run "retire_psc_after_migration" {
  command = plan

  assert {
    condition     = length(google_compute_global_forwarding_rule.vertex_psc) == 0 && length(google_compute_global_address.vertex_psc_ip) == 0
    error_message = "Retirement must remove both paid endpoint resources."
  }

  assert {
    condition     = google_dns_record_set.vertex_apex.rrdatas == tolist(["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"])
    error_message = "PSC removal must not remove Vertex private DNS connectivity."
  }
}

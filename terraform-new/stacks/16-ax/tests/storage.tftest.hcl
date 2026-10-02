mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789" }
  }
}
variables {
  project_id = "tesseracthub-480811"
  region     = "asia-south1"
}
run "private_recoverable_ax_storage" {
  command = plan
  assert {
    condition     = alltrue([for b in google_storage_bucket.ax : b.public_access_prevention == "enforced" && b.uniform_bucket_level_access && !b.force_destroy && b.versioning[0].enabled])
    error_message = "AX storage must be private, versioned, and protected from forced deletion."
  }
  assert {
    condition     = length(google_storage_bucket.ax) == 2 && alltrue([for g in google_storage_bucket_iam_member.runtime : strcontains(g.member, "/subject/ns/ax-system/sa/")])
    error_message = "Separate snapshot and backup buckets must use namespace-bound workload identities."
  }
}

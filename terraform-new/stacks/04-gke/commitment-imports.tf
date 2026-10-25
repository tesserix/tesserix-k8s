import {
  for_each = local.e2_commitments
  to       = google_compute_region_commitment.e2[each.key]
  id       = "projects/tesseracthub-480811/regions/asia-south1/commitments/${each.key}"
}

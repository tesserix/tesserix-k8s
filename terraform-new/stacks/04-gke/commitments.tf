# Adopt existing purchases only; these imports must not buy new commitments.
locals {
  e2_commitments = {
    "commitment-20260925-133025" = { auto_renew = false, resources = { VCPU = 18 } }
    "commitment-20260925-133159" = { auto_renew = true, resources = { VCPU = 8, MEMORY = 65536 } }
    "e2-cud-asia-south1"         = { auto_renew = true, resources = { VCPU = 30, MEMORY = 122880 } }
    "e2-ram-gap-40g-20261024"    = { auto_renew = false, resources = { MEMORY = 40960 } }
  }
}

resource "google_compute_region_commitment" "e2" {
  for_each   = local.e2_commitments
  name       = each.key
  project    = var.project_id
  region     = var.region
  plan       = "THIRTY_SIX_MONTH"
  type       = "GENERAL_PURPOSE_E2"
  auto_renew = each.value.auto_renew

  dynamic "resources" {
    for_each = [for kind in ["VCPU", "MEMORY"] : kind if contains(keys(each.value.resources), kind)]
    content {
      type   = resources.value
      amount = each.value.resources[resources.value]
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}


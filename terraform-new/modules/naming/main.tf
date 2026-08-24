locals {
  normalized_parts = [
    for part in [var.prefix, var.environment, var.resource] :
    trim(replace(lower(part), "/[^a-z0-9-]/", "-"), "-")
  ]
  untruncated = join("-", compact(local.normalized_parts))
  name        = trimsuffix(substr(local.untruncated, 0, min(length(local.untruncated), var.max_length)), "-")
}

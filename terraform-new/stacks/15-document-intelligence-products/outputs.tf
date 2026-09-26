output "releases" {
  description = "Registered document-intelligence product releases and their buckets"
  value       = { for name, r in local.releases : name => [for p in keys(local.bucket_purposes) : "${name}-doc-${p}-in"] }
}

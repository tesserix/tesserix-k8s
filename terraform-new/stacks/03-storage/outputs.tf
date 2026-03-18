# Storage Stack - Outputs

# =============================================================================
# KMS Outputs
# =============================================================================

output "kms_keyring_id" {
  description = "KMS keyring ID"
  value       = var.create_kms_keyring ? google_kms_key_ring.keyring[0].id : null
}

output "kms_keyring_name" {
  description = "KMS keyring name"
  value       = var.create_kms_keyring ? google_kms_key_ring.keyring[0].name : null
}

output "kms_key_ids" {
  description = "Map of KMS key IDs"
  value       = { for k, v in google_kms_crypto_key.keys : k => v.id }
}

output "kms_key_names" {
  description = "Map of KMS key names"
  value       = { for k, v in google_kms_crypto_key.keys : k => v.name }
}

# =============================================================================
# Bucket Outputs
# =============================================================================

output "bucket_names" {
  description = "Map of bucket names"
  value       = { for k, v in google_storage_bucket.buckets : k => v.name }
}

output "bucket_urls" {
  description = "Map of bucket URLs"
  value       = { for k, v in google_storage_bucket.buckets : k => v.url }
}

output "bucket_self_links" {
  description = "Map of bucket self links"
  value       = { for k, v in google_storage_bucket.buckets : k => v.self_link }
}

# =============================================================================
# Artifact Registry Outputs
# =============================================================================

output "docker_repository_ids" {
  description = "Map of Artifact Registry Docker repository IDs"
  value       = { for k, v in google_artifact_registry_repository.docker : k => v.id }
}

output "docker_repository_urls" {
  description = "Map of Artifact Registry Docker repository URLs (location-docker.pkg.dev/project/repo)"
  value = {
    for k, v in google_artifact_registry_repository.docker :
    k => "${v.location}-docker.pkg.dev/${var.project_id}/${v.repository_id}"
  }
}

# =============================================================================
# Secret Manager Outputs
# =============================================================================

output "secret_ids" {
  description = "Map of secret IDs"
  value       = { for k, v in google_secret_manager_secret.secrets : k => v.secret_id }
}

output "secret_names" {
  description = "Map of secret resource names"
  value       = { for k, v in google_secret_manager_secret.secrets : k => v.name }
}

output "secret_version_ids" {
  description = "Map of secret version IDs"
  value       = { for k, v in google_secret_manager_secret_version.versions : k => v.id }
}

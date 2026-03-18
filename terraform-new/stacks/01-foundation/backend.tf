# Foundation Stack - Backend Configuration
# State is stored in GCS with environment-specific prefix

terraform {
  backend "gcs" {
    # These values are provided via -backend-config or environment variables
    # bucket = "tesseract-terraform-states"
    # prefix = "stacks/prod/foundation"
  }
}

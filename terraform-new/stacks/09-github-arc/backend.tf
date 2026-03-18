# GitHub ARC Stack - Backend Configuration

terraform {
  backend "gcs" {
    # bucket = "tesseract-terraform-states"
    # prefix = "stacks/prod/github-arc"
  }
}

terraform {
  backend "gcs" {
    bucket = "tesseract-terraform-states"
    prefix = "stacks/prod/gke"
  }
}

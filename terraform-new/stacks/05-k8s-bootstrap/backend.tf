terraform {
  backend "gcs" {
    bucket = "tesseract-terraform-states"
    prefix = "stacks/prod/k8s-bootstrap"
  }
}

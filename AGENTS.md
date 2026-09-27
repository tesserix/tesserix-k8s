# Repository visibility

`tesserix/tesserix-k8s` must always remain public. Never make it private, including as part of a temporary public/CI/private workflow. This is a persistent user instruction.

# fe3dr secrets

Use in-cluster OpenBao as the default destination for fe3dr application secrets, with identifiers starting `fe3dr-`. Keep platform bootstrap, infrastructure and recovery secrets in GCP Secret Manager. Track remaining consumer cutovers and shared-secret coordination in issue #1159.

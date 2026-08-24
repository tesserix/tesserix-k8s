#!/usr/bin/env bash

set -euo pipefail

printf '%s\n' \
  'This legacy GitHub Actions WIF bootstrap is disabled.' \
  'Terraform applies are owned by Atlantis through GKE Workload Identity.' \
  'See terraform-new/docs/ATLANTIS_RUNBOOK.md for the reviewed bootstrap.' >&2
exit 1

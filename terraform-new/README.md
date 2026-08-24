# Terraform production control plane

This directory manages the production infrastructure in
`tesseracthub-480811`. Each stack has an isolated state object in
`gs://tesseract-terraform-states`, and `dependencies.yaml` is the canonical
graph for stack paths, state prefixes, dependencies, and execution phases.

Normal changes go through Atlantis:

1. Open a pull request that changes `terraform-new/`.
2. Atlantis plans every affected project and publishes `atlantis/plan`.
3. A current-head code-owner approval and all successful checks cause the
   approval relay to comment `atlantis apply`.
4. Atlantis rechecks `approved`, `mergeable`, and `undiverged`, applies the
   saved plan, and merges only after every apply succeeds.

The GitHub Actions Terraform workflow is validation-only. It has no cloud
credential permission and cannot plan or apply production infrastructure.

## Stack graph

Run `make deps` for the graph consumed by local tooling. The major phases are:

```text
00-state-bootstrap
  -> 01-foundation
     -> 02-network -> 04-gke -> 05-k8s-bootstrap -> 09-github-arc
                   -> 12-vertex
     -> 03-storage -> 06-workload-identity -> 07-app-secrets
     -> 08-communication-services
     -> 11-identity-platform
```

The managed prefixes are `stacks/prod/state-bootstrap` and the existing
`stacks/prod/{foundation,network,storage,gke,k8s-bootstrap,workload-identity,app-secrets,communication-services,github-arc,identity-platform,vertex}`
objects. Existing `stacks/prod/cloud-run`, `state/*`, `terraform/*`, and
`tesserix-governance` state is intentionally recorded as externally owned and
must not be deleted or migrated implicitly.

## Local checks

```bash
make deps
make fmt
make validate
DRY_RUN=true make plan STACK=02-network
```

`make plan` requires authenticated read access to GCS so dependency state can
be checked. `make apply` accepts only an existing saved plan; it never creates
an unreviewed replacement plan. Destroy is intentionally unavailable.

Bootstrap and production operating procedures are in
[`docs/ATLANTIS_RUNBOOK.md`](docs/ATLANTIS_RUNBOOK.md).

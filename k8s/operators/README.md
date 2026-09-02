# Kubernetes operators

Each operator owns one directory: `k8s/operators/<operator>/`.

- `resources.yaml` or `operator.yaml` defines the CRDs, controller, identity,
  and RBAC.
- `claims/` contains the custom resources reconciled by that controller.
- The operator-level `kustomization.yaml` includes both, so one Argo CD
  Application deploys an operator and its claims together.

Add a claim only to its owning operator's `claims/` directory and register it
in that directory's `kustomization.yaml`. Do not create a second top-level
claims tree or a separate Argo CD Application for an operator's claims.

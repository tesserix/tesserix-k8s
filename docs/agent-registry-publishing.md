# Agent Registry publishing runbook

This runbook explains how reviewed Agent manifests move from Git into the
production Agent Registry, how the publishing endpoint is protected, and how a
new repository can be onboarded safely.

The design decision behind the publisher route is recorded in
[ADR 0001](adr/0001-agent-registry-github-publisher-route.md).

## Current production flow

The public Registry and its publisher have different purposes:

| Endpoint | Purpose | Expected browser result |
|---|---|---|
| `https://aregistry.tesserix.app` | Registry UI and public Agent Card reads | UI or HTTP 200 |
| `https://publish-aregistry.tesserix.app/v0/apply` | Machine-only manifest publication | HTTP 403 |

The publisher bypasses Cloudflare Bot Fight Mode through the external Istio
gateway. It remains fail-closed: a request must carry both a short-lived GitHub
OIDC token and the tenant-scoped Registry deploy key.

The current route authorizes exactly:

- repository `tesserix/ai-agents`;
- branch `refs/heads/main`;
- event `workflow_dispatch`;
- workflow `tesserix/ai-agents/.github/workflows/publish.yml@refs/heads/main`;
- OIDC audience `agentregistry-publisher.tesserix.app`; and
- `POST /v0/apply` on `publish-aregistry.tesserix.app`.

The OIDC audience is an authentication contract, not a hostname. Do not rename
it when changing the DNS name unless the workflow and Istio validation are
changed together.

## What is automated

The `tesserix/ai-agents` `Publish` workflow has three release modes:

| Event | Image | Registry manifests |
|---|---|---|
| Pull request | Build and validate; do not push | Skipped |
| Push or merge to `main` | Build and push branch/SHA tags to GHCR | Skipped |
| Manual dispatch on `main` | Build and push | Publish every reviewed `registry/*.yaml` file |

Registry publication is intentionally a manual release gate. After a maintainer
dispatches the workflow, GitHub obtains the OIDC token at runtime and sends each
manifest automatically. No operator should retrieve, print, paste, or store the
OIDC token.

## Publish Kora Agent manifests

### 1. Create a reviewed change

Work in the existing `tesserix/ai-agents` repository:

```bash
git switch main
git pull --ff-only origin main
git switch -c feat/<short-agent-change>
```

Edit or add the Agent manifests under `registry/`. Keep tenant, image, model,
skills, and MCP references explicit in the manifest. Never add a deploy key,
provider credential, API token, or copied production response to Git.

### 2. Validate locally

Run the same checks as CI:

```bash
uv sync --frozen
uv run ruff format --check .
uv run ruff check .
uv run mypy --strict src/
uv run pytest --cov --cov-fail-under=90
uv build
actionlint
```

Also inspect the exact diff:

```bash
git diff --check
git diff -- registry/ .github/workflows/publish.yml tests/
```

### 3. Commit, push, and merge

Resolve the Git identity from the remote before committing. For the Tesserix
remote, use the Tesserix identity:

```bash
git remote get-url origin
git config user.name sam123ben
git config user.email samyak.rout@gmail.com
git add registry/ tests/
git commit -m "feat(registry): publish <agent-name>"
git push -u origin HEAD
gh pr create --base main --fill
gh pr checks --watch
```

Merge only after required reviews and checks pass. Do not bypass branch
protection or force-push `main`:

```bash
gh pr merge --squash --delete-branch
```

The merge builds and pushes the Agent image. It does not publish Registry
manifests.

### 4. Dispatch the publication gate

Dispatch the protected workflow from `main`:

```bash
gh workflow run publish.yml --repo tesserix/ai-agents --ref main
gh run list --repo tesserix/ai-agents --workflow publish.yml \
  --event workflow_dispatch --limit 1
gh run watch <run-id> --repo tesserix/ai-agents --exit-status
```

Both the `image` and `registry` jobs must succeed. A failed Registry job leaves
the previously published catalog unchanged and can be retried safely because
publication is idempotent.

### 5. Verify the result

Check the public Agent Cards, not the protected publisher URL:

```bash
curl --fail --silent --show-error \
  "https://aregistry.tesserix.app/v0/agents/<agent-name>/card?namespace=kora"
```

Platform maintainers may also verify the GitOps and routing state read-only:

```bash
kubectl -n argocd get application \
  agentic-istio agentic-registry external-dns-agentregistry-publisher
kubectl -n istio-ingress get certificate agentregistry-publisher
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  --request POST https://publish-aregistry.tesserix.app/v0/apply
```

The last command must return `403`. That proves unauthenticated traffic cannot
reach the Registry write API; it is not a failed deployment.

## Onboard another publishing repository

The current endpoint does not authorize DevAI or any repository other than
`tesserix/ai-agents`. Copying `publish.yml` into another repository will return
HTTP 403.

Onboarding is a security and GitOps change. The platform maintainer must:

1. Define the tenant and the exact repository, branch, event, workflow path,
   and OIDC audience that may publish.
2. Prefer a dedicated publisher hostname and policy for the new trust domain.
   Do not append independent `DENY` rule sets for multiple repositories: their
   negative claim matches can deny each other's valid tokens.
3. Add or update the certificate, Istio Gateway, VirtualService,
   RequestAuthentication, AuthorizationPolicy, ExternalDNS selection, and
   regression tests in `tesserix-k8s`.
4. Provision a tenant-scoped Registry deploy key into the target repository as
   a protected GitHub Actions secret. Never put its value in Git, a command
   argument, a workflow log, an issue, or documentation.
5. Give the publishing job only `contents: read` and `id-token: write`; pin
   third-party Actions by commit SHA.
6. Validate an unauthenticated request returns 403, then run the authorized
   workflow and verify only the intended tenant's Agent Cards changed.

Keep public reads behind Cloudflare. Do not disable Bot Fight Mode zone-wide to
make a publisher work.

## Troubleshooting

| Symptom | Meaning or next check |
|---|---|
| Browser shows `RBAC: access denied` | Expected. Browsers do not have the repository-bound OIDC token. |
| Workflow receives HTTP 403 | Check repository, ref, event, workflow reference, audience, and that the run is a manual dispatch from `main`. |
| Workflow rejects the deploy key locally | The protected secret is missing or malformed. Do not print it; check repository secret metadata. |
| HTTP 404 from an Agent Card | Confirm the namespace and Agent name, then confirm the `registry` job applied that manifest. |
| HTTP 207 from `/v0/apply` | At least one object was rejected. The workflow prints only the object-level errors and fails the run. |
| DNS or TLS fails | Check the `agentic-istio` and `external-dns-agentregistry-publisher` Argo CD applications and the certificate status. |

## Rollback

For an Agent manifest, revert the reviewed change, merge it, and manually
dispatch `publish.yml` again. For publisher infrastructure, revert the owning
`tesserix-k8s` commit and allow Argo CD to reconcile. Do not patch production
resources imperatively.

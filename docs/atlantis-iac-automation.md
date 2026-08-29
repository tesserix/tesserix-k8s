# Terraform in a pull request: how Atlantis changed our infrastructure work

We moved our production Terraform onto Atlantis on 24 August 2026. Before that,
changing infrastructure meant running `terraform apply` from a laptop or firing
a GitHub Actions workflow by hand. Now the pull request is the whole interface.
You open it, a plan shows up as a comment, a reviewer approves, and the change
applies and merges on its own.

This is a short write-up of what we built, why, and what it feels like day to
day.

## What Atlantis is

Atlantis is a small server that sits between GitHub and Terraform. It listens
for pull request events through a webhook. When a PR touches Terraform code, it
runs `terraform plan` and posts the output back as a PR comment. When someone
comments `atlantis apply`, it runs `terraform apply` using the plan file it
already saved, so the thing that gets applied is exactly the thing that was
reviewed.

That last point is the whole reason it exists. A plan you read in a terminal
three hours ago is not evidence of anything. A plan attached to a commit, that
apply is forced to reuse, is.

It is open source, it runs as a normal container, and it holds no state beyond
a disk of working directories and locks.

## Where it runs

Atlantis v0.47.1 runs in our production GKE cluster in the `atlantis`
namespace. Argo CD owns it like everything else: there is an Application at
`argocd/prod/infrastructure/atlantis.yaml` pointing at a wrapper chart in
`charts/thirdparty/atlantis`, which depends on the upstream Atlantis chart
6.15.0. Sync wave 4, automated sync, self heal on.

The wrapper chart exists so the parts that are ours stay ours: the namespace,
the External Secrets, the network policy, the Istio VirtualService, and the
oauth2-proxy in front of the web console.

A few choices worth calling out.

**No service account keys.** The Kubernetes service account `atlantis/atlantis`
is bound through Workload Identity to a Google service account,
`tesseract-prod-atlantis@tesseracthub-480811`. That binding is itself Terraform,
in `terraform-new/stacks/06-workload-identity/atlantis.tf`. Atlantis gets its
GCP credentials from the metadata server and nothing is written to disk.

**All secrets come from GCP Secret Manager.** The GitHub App ID, installation
ID, private key and webhook secret land in the `atlantis-vcs` secret through
External Secrets. Terraform input variables such as the Cloudflare API token
arrive as environment variables through `atlantis-terraform-vars`. Nothing
sensitive is in the repository.

**The console is behind single sign on.** The Istio VirtualService routes
`/events` straight to Atlantis, because GitHub cannot complete an OIDC login and
the webhook is already authenticated by its HMAC signature. Every other path
goes through oauth2-proxy against Zitadel at `auth.tesserix.app`, with an
explicit list of allowed email addresses. `/api` and `/status` return 404 at the
gateway, so the remote command API is simply not reachable.

**The container is locked down.** Read only root filesystem, non root user, all
capabilities dropped, seccomp on. `kubectl` is not baked into the image; an init
container downloads a pinned version and checks its SHA-256 before Atlantis can
use it.

## The stack graph

Our Terraform is split into twelve stacks, from `00-state-bootstrap` through
`12-vertex`. They are not independent. Networking has to exist before GKE, GKE
before the Kubernetes bootstrap, and so on.

The repository's `atlantis.yaml` encodes that as a real dependency graph:

```yaml
version: 3
automerge: true
parallel_plan: true
parallel_apply: true
abort_on_execution_order_fail: true

projects:
  - name: 04-gke
    dir: terraform-new/stacks/04-gke
    execution_order_group: 4
    depends_on: [02-network]
    autoplan:
      when_modified: ["*.tf", "../../environments/prod/terraform.tfvars"]
      enabled: true
```

Every stack declares its `execution_order_group` and its `depends_on`. Atlantis
runs groups in order and runs everything inside a group in parallel. If a group
fails, `abort_on_execution_order_fail` stops the ones after it instead of
applying half a change.

`autoplan.when_modified` is what keeps the noise down. Editing a file under
`stacks/12-vertex` plans `12-vertex` and nothing else. A change to the shared
`environments/prod/terraform.tfvars` plans everything that reads it.

There is a test, `tests/test_atlantis_terraform_automation.py`, that reads the
stack dependency file and the Atlantis config and asserts they agree: same set
of stacks, same dependencies, same ordering, autoplan enabled everywhere. If
somebody adds a stack and forgets the Atlantis entry, CI says so.

## What actually happens when you open a PR

Here is the full path for a change to production infrastructure.

**1. You push a branch and open a PR.**

**2. Atlantis plans, by itself.** The webhook fires, Atlantis works out which
stacks your files touch, and runs `init` plus `plan` for each one, in dependency
order, in parallel where it can. The plan runs with
`-var-file=../../environments/prod/terraform.tfvars`, so it is a real production
plan and not an approximation. The output comes back as a PR comment and as an
`atlantis/plan` commit status. Old plan comments are hidden as new ones arrive,
so the PR does not turn into a wall of stale output.

**3. Your normal checks run too.** Terraform formatting and offline validation,
PR validation, Helm lint. Those are ordinary GitHub Actions and they have no
cloud credentials at all.

**4. A reviewer approves.** Code owner review is required. Approvals are
dismissed when new commits are pushed, so an approval always refers to the code
that is actually there.

**5. The apply is requested automatically.** This is the piece we wrote.
`.github/workflows/atlantis-auto-apply.yml` watches for review, check run,
status and workflow run events. When one arrives it re-checks everything from
scratch:

- the PR is open, not a draft, and not from a fork
- there is an `APPROVED` review whose `commit_id` equals the current head SHA
- an `atlantis/plan` status exists and is successful
- no other commit status is failing
- every other check run has finished as success, neutral or skipped

Only if all of that holds does it post a single comment: `atlantis apply`.

It is deliberately boring about repeating itself. Each comment carries a hidden
marker built from the head SHA and the IDs of the approving reviews:

```
<!-- atlantis-auto-apply:<head-sha>:<approval-ids> -->
```

Before posting, it looks for that exact marker in the existing comments. So the
five events that arrive within the same second produce one apply request, not
five. Push a new commit or get a new approval and the marker changes, which is
the only way it will ask again.

The workflow has `issues: write` and read on everything else. It cannot touch
the cloud. All it can do is ask Atlantis, politely, in a comment.

**6. Atlantis checks again anyway.** The relay is a convenience, not the
control. Atlantis's own server side config requires `approved`, `mergeable` and
`undiverged` before any apply. That config lives on the server; the repository
cannot override it, because `allowed_overrides` is empty and
`allow_custom_workflows` is false. Fork PRs and draft PRs are ignored outright.

**7. It applies the saved plan.** Not a fresh plan. The one you reviewed.

**8. It merges.** `automerge: true` merges the PR, but only after every affected
project has applied successfully. If any apply fails, nothing merges and the
branch stays exactly where it is.

There is a second guard on the GitHub side. A ruleset named
`atlantis-apply-protection` makes `atlantis/apply` a required status check on
`main`. So even if somebody tried to merge by hand, GitHub would refuse until
Atlantis had actually applied.

## Screenshots

<!-- SCREENSHOT: atlantis-pr-plan.png -->
![Atlantis posting a plan on a pull request](images/atlantis/atlantis-pr-plan.png)

*Atlantis posts the plan for the affected stack as a PR comment, plus an
`atlantis/plan` commit status.*

<!-- SCREENSHOT: atlantis-auto-apply-comment.png -->
![The auto apply relay requesting an apply](images/atlantis/atlantis-auto-apply-comment.png)

*After approval and green checks, the relay posts one `atlantis apply` comment.*

<!-- SCREENSHOT: atlantis-apply-and-merge.png -->
![Apply output followed by the automatic merge](images/atlantis/atlantis-apply-and-merge.png)

*Atlantis applies the saved plan and merges the PR once every project succeeds.*

<!-- SCREENSHOT: atlantis-console-locks.png -->
![The Atlantis console showing current locks](images/atlantis/atlantis-console-locks.png)

*The console at `atlantis.tesserix.app`, behind Zitadel single sign on, showing
in-flight plans and locks.*

## What it changed for us

**The plan is the review.** Reviewers used to read a Terraform diff and imagine
the consequences. Now the consequences are in the thread, generated against real
production state, before anyone approves.

**One way in.** We deleted the old Actions workflow that used Workload Identity
Federation and could apply or destroy on a manual dispatch. Two apply paths
meant two sets of assumptions about what had been reviewed. There is one now.
`terraform.yml` still runs, but it only does formatting and offline validation
and holds no credentials.

**Small changes stopped being expensive.** A one line change to a stack used to
mean authenticating, initialising, planning, reading, applying, and then
remembering to push the branch. Now it is a PR and an approval. The waiting is
Terraform's, not yours, and it happens while you do something else.

**Ordering is not a person's job anymore.** Nobody has to remember that network
comes before GKE. The graph is in the config, it is unit tested, and Atlantis
enforces it.

**Nothing applies without a fresh approval.** Approvals are dismissed on push,
the relay matches approvals against the head SHA, and Atlantis independently
requires `undiverged`. A stale approval cannot carry a new commit into
production.

## The parts that took work

The rollout was not one commit. Getting the webhook past the Istio gateway
without sending GitHub into an OIDC redirect took the VirtualService ordering
described above. Plans initially ran without the production tfvars and produced
misleading diffs. Putting the console behind Zitadel meant working through
oauth2-proxy cookie encoding and cluster DNS for the proxy pod.

We also spent time on the ordinary case of "there is nothing to apply". We
briefly built an extra workflow to publish a synthetic apply status for PRs with
no Terraform in them, then found that Atlantis already publishes a successful
0/0 apply status in that case, and deleted it. Requiring `atlantis/apply` on
`main` is safe on its own.

Each of these was verified on a throwaway PR that was closed without applying or
merging, which is worth doing before you let a machine apply to production on
your behalf.

## If you want the details

Bootstrap order, GitHub App permissions, the full Secret Manager list, and what
to do when an apply fails are in
[`terraform-new/docs/ATLANTIS_RUNBOOK.md`](../terraform-new/docs/ATLANTIS_RUNBOOK.md).
The GitHub side is summarised in
[`terraform-new/docs/GITHUB_WORKFLOW_INTEGRATION.md`](../terraform-new/docs/GITHUB_WORKFLOW_INTEGRATION.md).

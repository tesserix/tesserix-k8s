# Mark8ly UAT Smoke Test Pipeline

Runbook for the **Playwright e2e Job → Kargo smoke gate → Slack alert** chain
that gates prod auto-promotion in the mark8ly product pipeline.

---

## What this gives you

Every Kargo smoke promotion in the `kargo-mark8ly` project triggers a fresh
Playwright run against UAT. If the suite ultimately fails (after 3 attempts):

1. The smoke `Stage` transitions to `health=Errored`.
2. The downstream prod `Stage` (`sources: [smoke]`) sees no eligible Freight
   and therefore **does not auto-promote** to prod.
3. A Slack alert lands in `#mark8ly-smoke-test-verification` with the failure
   details, links to the failing Argo CD Application, and the kubectl one-liner
   to inspect Job logs.

If the suite passes, the smoke Stage goes `Healthy`, prod auto-promotes the
same Freight, and no Slack noise.

---

## Topology

```
                  GitHub push (mark8ly app code)
                            │
                            ▼
              CI builds + pushes image to GHCR/GAR
                            │
                            ▼
              Kargo Warehouse `services` discovers tag
                            │
                            ▼
                ┌──────────────────────┐
                │ Stage `uat` (auto)   │  →  argocd-update writes image.tag
                └──────────────────────┘     onto the 8 mark8ly-uat-* Apps;
                            │                Argo CD rolls them.
                            ▼
                ┌──────────────────────┐
                │ Stage `smoke` (auto) │  →  argocd-update bumps image.tag on
                └──────────────────────┘     the mark8ly-uat-e2e-tests App;
                            │                Argo CD recreates the Job (sync-
                            │                hook); Job runs Playwright
                            │                against UAT URLs; Kargo waits for
                            │                App health.
                            │
            ┌───────────────┴───────────────┐
            │                               │
       (Job succeeds)                  (Job fails)
            │                               │
            ▼                               ▼
   Stage smoke=Healthy            Stage smoke=Errored
            │                               │
            ▼                               ├── argocd-notifications fires
   Stage prod auto-promote                  │   on-mark8ly-uat-smoke-failed
   the Freight via                          │   trigger
   argocd-update on the 8                   │            │
   mark8ly-* (prod) Apps                    │            ▼
                                            │   Slack chat.postMessage to
                                            │   #mark8ly-smoke-test-verification
                                            │
                                            └── prod Stage sees no eligible
                                                Freight (sources: [smoke]) →
                                                NO auto-promotion to prod
```

---

## Pieces (with file pointers)

### 1. The Playwright runner image

Built from the **playwright-tests** repo (separate from mark8ly app repo).

| Item | Location | Notes |
| --- | --- | --- |
| Dockerfile | `tesserix/playwright-tests:Dockerfile` | Wolfi-base + system Chromium (low-CVE, distroless-style, runs as nonroot UID 65532). |
| CI workflow | `tesserix/playwright-tests:.github/workflows/build-mark8ly-uat-e2e.yml` | Path-triggered on `mark8ly/**` and `Dockerfile`. Pushes `ghcr.io/tesserix/mark8ly-uat-e2e:main-<sha>` and `:latest`. |
| Suite config | `tesserix/playwright-tests:mark8ly/config.ts` | Reads `TARGET_ENV` / `TARGET_SLUG` from env; UAT defaults to `tesserix-store` slug under `*-uat.mark8ly.com`. |
| Credentials | **never in source** | Suite throws at startup if `MARK8LY_ADMIN_EMAIL` / `_PASSWORD` env vars are missing. CI / Job both supply via env. |

### 2. The in-cluster Job

| Item | Location | Notes |
| --- | --- | --- |
| Helm chart | `charts/apps/mark8ly-uat-e2e-tests/` | Single Job template. `argocd.argoproj.io/hook: Sync` recreates the Job on every Argo CD sync. |
| Argo CD Application | `argocd/prod/apps/mark8ly-uat/e2e-tests.yaml` | Authorized for Kargo's `kargo-mark8ly:smoke` Stage. `retry.limit: 0` so failures surface to Kargo immediately. |
| Job retries | `values.yaml: backoffLimit: 2` | 3 total attempts — absorbs transient flakes, fails on real bugs. |

### 3. Credential supply chain

```
GCP Secret Manager  →  ESO ExternalSecret  →  K8s Secret  →  Pod env
─────────────────      ────────────────────      ──────────       ─────
prod-mark8ly-uat-           mark8ly-uat-           mark8ly-uat-     MARK8LY_ADMIN_EMAIL
  playwright-creds            playwright-creds       playwright-     MARK8LY_ADMIN_PASSWORD
  (JSON: email,                (in mark8ly-uat        creds (envFrom)
   password)                    namespace)
```

| Item | Location |
| --- | --- |
| Test creds in GCP SM | `prod-mark8ly-uat-playwright-creds` (JSON `{email, password}`) |
| ExternalSecret | `external-secrets/prod/mark8ly-uat/externalsecret.yaml` (`mark8ly-uat-playwright-creds` block) |
| Pod wiring | `charts/apps/mark8ly-uat-e2e-tests/templates/job.yaml` — `envFrom.secretRef` |

### 4. Kargo smoke Stage

| Item | Location |
| --- | --- |
| Stage definition | `kargo-manifests/projects/mark8ly/stages/smoke.yaml` |
| Promotion step | `argocd-update` on `mark8ly-uat-e2e-tests` App; bumps `image.tag` to the discovered Freight tag. |
| Failure handling | Step waits for App health. If App reports `Failed`, the step Errors → Stage Errored → prod blocked. |

### 5. Slack alerting

| Item | Location |
| --- | --- |
| Slack bot token | `prod-argocd-notifications-slack-token` (xoxb-…, GCP SM) |
| ExternalSecret | `external-secrets/prod/argocd/notifications.yaml` → `argocd-notifications-secret` (key `slack-token`) |
| Trigger / template / service | helm release `argocd` values; the helm overlay is checked in at `docs/argocd/notifications-overlay.yaml` (re-apply via `helm upgrade --reuse-values -f`) |
| App subscription | annotation `notifications.argoproj.io/subscribe.on-mark8ly-uat-smoke-failed.slack` on `argocd/prod/apps/mark8ly-uat/e2e-tests.yaml` |
| Channel | `#mark8ly-smoke-test-verification` (Slack workspace `Unidev`) |
| Bot user | `@mark8lyplaywritetestn` (App: `mark8ly-playwright`) |

#### What the Slack message looks like

```
🚨 Mark8ly UAT smoke test failed — prod auto-promotion blocked

┌─[red]──────────────────────────────────────────────┐
│ mark8ly-uat-e2e-tests failed in UAT  (clickable →  │
│                                       Argo CD App) │
│                                                    │
│ Failure                                            │
│ one or more synchronization tasks completed        │
│ unsuccessfully (retried 3 times).                  │
│                                                    │
│ Sync Revision     Image Tag                        │
│ `13a390e487ab`    `main-bd4584b`                   │
│                                                    │
│ Failed Resource — Job/mark8ly-uat-e2e-tests        │
│ ┌────────────────────────────────────────────────┐ │
│ │ Job has reached the specified backoff limit    │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ Triage commands                                    │
│ ┌────────────────────────────────────────────────┐ │
│ │ kubectl -n mark8ly-uat get pods …             │ │
│ │ kubectl -n mark8ly-uat logs <POD>             │ │
│ │ kubectl -n mark8ly-uat cp <POD>:/app/playwright│ │
│ │  -report ./playwright-report                   │ │
│ │ open ./playwright-report/index.html            │ │
│ └────────────────────────────────────────────────┘ │
│                                                    │
│ Quick links                                        │
│ Argo CD App · Kargo Project · Smoke Stage          │
│                                                    │
│ Block prod auto-promotion until smoke goes Healthy │
│                                                    │
└────────────────────────────────────────────────────┘
```

The message gives on-call enough context to know **which** App failed,
**why** at the K8s/Argo CD level, the **exact image tag** under test, and
**copy-paste commands** to dig into the actual Playwright failure (test
name, assertion error, screenshots) without leaving Slack.

#### Future enhancement: inline test-failure summary

The current message exposes the *Kubernetes* failure ("Job has reached
the specified backoff limit") and points operators at the Job logs for
the actual test details. A nicer-but-bigger lift is having the
Playwright reporter write a structured failure summary
(failing-test name + first 200 chars of the assertion error) to a
location the notifications template can read. Two viable approaches:

1. **Webhook intermediary** — Add `service.webhook` to argocd-notifications,
   target a small in-cluster service that fetches Job logs via the K8s
   API and re-posts an enriched Slack message. Most flexible, ~50 lines
   of Go.
2. **K8s Secret hand-off** — Custom Playwright reporter writes the
   summary into a Secret in the `argocd` namespace; a second template
   renders that Secret's content via `secrets.get` template helper.
   Lighter-weight, zero extra runtime services.

Neither is needed today — the kubectl one-liner gets the full report
in one command — but worth considering if Slack-first triage becomes
more important.

---

## Failure mode reference

### Real test failure (e.g. selector breaks)

1. Pod runs Playwright, exits non-zero on the failing test.
2. `restartPolicy: Never` — pod stays Failed.
3. Job creates pod #2 → fails. Job creates pod #3 → fails.
4. `status.failed (3) > backoffLimit (2)` → Job condition `type=Failed`,
   `reason=BackoffLimitExceeded`.
5. Argo CD sees Job `hookPhase=Failed` → App `OperationPhase=Failed`,
   `Health=Degraded`.
6. argocd-notifications-controller's trigger condition matches:
   ```
   app.metadata.name == 'mark8ly-uat-e2e-tests'
   && app.status.operationState.phase in ['Failed','Error']
   ```
7. Slack message posted. `notified.notifications.argoproj.io` annotation
   stamped to dedupe.
8. Kargo's argocd-update step Errored → Promotion CR `phase=Errored` →
   smoke Stage `health=Errored` → prod `requestedFreight` empty.

### Image pull failure (typo, non-existent tag)

Same chain as above, just triggered earlier. Pod stuck in
`ErrImagePull`/`ImagePullBackOff` → eventually counts toward `status.failed`
when the kubelet gives up retrying. Slack alert fires identically.

### Transient blip (one test fails, then passes on retry)

Pod #1 fails → Job creates pod #2 → passes → Job `succeeded > 0`,
`active == 0` → Argo CD `Healthy` → smoke Stage Healthy → prod
auto-promotes. No Slack noise. (This is what `backoffLimit: 2` buys us.)

---

## Verifying the chain end to end

We verified this live on **2026-05-07** with a controlled test:

```
1. Captured the live good image tag: main-bd4584b
2. Disabled selfHeal on the App (so the patch wouldn't be reverted).
3. Patched image.tag → "force-failure-test-9z9z9z9" (non-existent).
4. Triggered an Argo CD sync.
5. Pod went ErrImagePull. Killed pods 3x to burn through backoffLimit fast.
6. Job condition: type=Failed, reason=BackoffLimitExceeded, failed=3.
7. App OperationPhase: Failed.
8. argocd-notifications-controller fired the trigger; Slack message posted
   to #mark8ly-smoke-test-verification (timestamp matches).
9. Reverted image.tag → main-bd4584b, re-enabled selfHeal.
```

Re-running the verification later: same patch sequence; should always produce
a Slack message within ~30s of the Job hitting `BackoffLimitExceeded`.

---

## Operating cookbook

### Force a test re-run for the latest Freight

```bash
# Find the latest smoke Promotion + retry it from the Kargo UI, OR:
kubectl -n argocd patch app mark8ly-uat-e2e-tests \
  --type merge -p '{"operation":{"sync":{}}}'
```

### Look at the most recent Job logs

```bash
kubectl -n mark8ly-uat get pods -l app.kubernetes.io/name=mark8ly-uat-e2e-tests
kubectl -n mark8ly-uat logs job/mark8ly-uat-e2e-tests
```

(Jobs auto-clean after `ttlSecondsAfterFinished: 600` — be quick after a fail.)

### Bypass smoke for an emergency hot-fix

Edit `kargo-manifests/projects/mark8ly/stages/prod.yaml`:

```yaml
sources:
  direct: true   # was: stages: [smoke]
```

Commit, push, promote, **revert immediately after**. The Slack alert still
fires for the failed UAT smoke run; you've just bypassed the gate for prod.

### Tighten / loosen the retry budget

| Want | Change |
| --- | --- |
| Fail fast (no retries) | `charts/apps/mark8ly-uat-e2e-tests/values.yaml` → `backoffLimit: 0` |
| More forgiving (5 attempts) | `backoffLimit: 4` |
| Faster Argo CD signal back to Kargo | already at `retry.limit: 0` (don't loop the sync) |

### Rotate the Slack bot token

```bash
# Create new token in Slack app UI, then:
NEW_TOKEN=$(cat /path/to/new/token)
printf '%s' "$NEW_TOKEN" | gcloud secrets versions add prod-argocd-notifications-slack-token \
  --project=tesseracthub-480811 --data-file=-

# ESO refreshInterval is 1h; force immediate sync:
kubectl -n argocd annotate externalsecret argocd-notifications-slack-token \
  force-sync="$(date +%s)" --overwrite
kubectl -n argocd rollout restart deploy/argocd-notifications-controller
```

### Subscribe more channels / change the channel

Edit the App annotation in `argocd/prod/apps/mark8ly-uat/e2e-tests.yaml`:

```yaml
annotations:
  notifications.argoproj.io/subscribe.on-mark8ly-uat-smoke-failed.slack: "channel-1;channel-2"
```

Channels are separated by `;`. Bot needs `chat:write.public` (already granted)
to post without explicit invite.

---

## Known gaps

- The `mark8ly-uat-e2e-tests` Argo CD App's helm `image.tag` parameter is
  written by Kargo's argocd-update step; Git tracks `latest` as the default.
  ArgoCD's `ignoreDifferences` keeps selfHeal from reverting Kargo's writes.
- Argo CD itself is helm-installed (not GitOps-managed). The
  `notifications.enabled: true` lives in the live helm release values; if you
  re-install argo-cd from scratch, re-apply the overlay used in the May 2026
  setup (see commit `13a390e4` in tesserix-k8s for the exact YAML).
- Bot token has `chat:write` + `chat:write.public` scopes only. Reading
  channel history (`channels:history`) is intentionally NOT granted — keeps
  blast radius minimal if the token leaks.

---

*Last updated: 2026-05-07 (initial write + live verification).*

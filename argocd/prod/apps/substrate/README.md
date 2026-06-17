# Agent Substrate — STAGED (not deployed)

These ArgoCD Applications are **ready but intentionally NOT wired** into an
app-of-apps kustomization, and use **manual sync** (no `automated`), so their mere
presence in the repo does NOT deploy anything. They are blocked on a GKE-Sandbox
node pool — without it the WorkerPool's gVisor pod can't schedule.

**Do not deploy these ad hoc.** Follow the ordered runbook:
`devai/docs/agentic/SUBSTRATE-SETUP.md` (step 1 = the gcloud sandbox pool, step 2 =
pin chart versions, step 3 = sync these apps, step 4 = enable substrate on kagent).

Tracking: tesserix/devai #70 (GO/NO-GO), #71 (install), epic #69.

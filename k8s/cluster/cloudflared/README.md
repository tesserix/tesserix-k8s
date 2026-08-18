# cloudflared tunnel routing is NOT configured here

This directory previously held `configmap.yaml`, a `cloudflared-config`
ConfigMap declaring `namespace: ingress` and a full `ingress:` rule list.

**Nothing consumed it.** It was referenced by no kustomization and no ArgoCD
Application, and every fact in it had drifted from reality:

| The file said | Reality |
|---|---|
| ConfigMap in namespace `ingress` | cloudflared runs in namespace `cloudflared`; the `ingress` namespace has no pods |
| tunnel `6a756e3d-b7e6-492b-ab01-7e6f7d727951` | live tunnel is `2b78323c-aa85-4b96-b703-c831357e7d33` |
| origin `istio-ingressgateway.istio-system` | the Service is in `istio-ingress` |
| 6 ingress rules | the live tunnel serves 25+ |

It was deleted rather than corrected because correcting it would have produced
a file that still configures nothing while looking even more authoritative.

## Where routing actually lives

The deployment runs `cloudflared tunnel run --token $(TUNNEL_TOKEN)` — a
**remotely-managed** tunnel. Its ingress rules live in Cloudflare's API, not in
this repository or in Kubernetes.

To add or change a hostname, follow
`charts/infrastructure/cloudflared/CLOUDFLARE_SETUP_PROD.md`.

**The dangerous part, stated once here because the API makes it easy to get
wrong:** the configuration endpoint is a `PUT` that REPLACES the entire ingress
array. There are 25+ live rules across `tesserix.app`, `mark8ly.com` and others.
A PUT built from a partial list silently deletes every rule it omits, and the
first symptom is other products' traffic 404ing. Always GET the current
configuration, modify the array, and PUT the whole thing back.

## Consequence for GitOps

Tunnel routing is the one part of the ingress path that is **not** in git. A
hostname can be added or removed with no pull request and no audit trail beyond
Cloudflare's own. That is worth knowing before assuming this repository
describes how traffic reaches the cluster.

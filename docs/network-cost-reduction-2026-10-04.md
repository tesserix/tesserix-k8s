# Production network cost reduction — 2026-10-04

First-stage changes deployed through [PR #1307](https://github.com/tesserix/tesserix-k8s/pull/1307).
Active account: `unidevidp@gmail.com`.
Project: `tesseracthub-480811`; context:
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.

## Evidence and expected savings

October 1–2 detailed billing export shows approximately AUD 178 per 30 days
for inter-zone transfer and AUD 46 for NAT processing. The monitoring shutdown
already removed a measured candidate AUD 56 per 30 days of cross-zone traffic.
October 3 is incomplete in the export and must not be extrapolated as a full day.

NAT is already Standard tier, dynamically allocates ports and uses one IP.
Private Google Access is already enabled on the production subnet. Recent NAT
metrics show about 14.2 GiB sent/received over 24 hours. NAT remains necessary
for Cloudflare tunnel connections and other non-Google internet dependencies.
Removing it would break those connections.

The Vertex PSC endpoint costs AUD 0.3416/day, or AUD 10.25 per 30 days.
All four private Google API VIPs returned HTTP 200 for authenticated Vertex
model-list requests from the existing DevAI pod using its own Workload Identity,
with validated TLS and the real asia-south1 Vertex hostname. Client behavior
must also be verified after the DNS change before retiring PSC. Terraform migration plan changes only the DNS zone
description and its apex/wildcard A records, preserving existing PSC resources
and IAM. A separate retirement review plan deletes only `vertexapis` and
`vertex-psc-ip` after DNS migration. No unrelated IAM changes were planned.

No fixed forwarding-rule saving is claimed for removing only the unused internal
load balancer: the billing export charges a minimum forwarding-rule SKU while
the required public custom-domain load balancer remains. Verify the eventual
billing effect rather than assuming half the charge disappears.

Regional endpoints such as `asia-south1-aiplatform.googleapis.com` do not fall
under the existing `aiplatform.googleapis.com` private zone. They already use
Private Google Access; do not describe this wildcard as covering those names.

## GitOps changes

1. Set `PreferSameZone` on the production main ingress Service, both shared Valkey
   HAProxy Services and both shared PostgreSQL pooler Services. Add the equivalent
   Istio preference to generated waypoint Services through Gateway infrastructure
   annotations. PreferSameZone permits healthy endpoints in other zones when a local
   endpoint is unavailable; it does not impose `internalTrafficPolicy: Local`.
   Database read/write roles, Valkey primary selection, TLS, selectors, volumes
   and replica counts are unchanged. Rendering against baseline confirms locality
   hints are the only changes in these resources.
2. Park `istio-ingressgateway-internal` in namespace `istio-ingress`: replicas 0,
   HPA disabled and Service type ClusterIP. No native Istio Gateway selects
   `istio: ingressgateway-internal`. The inspected main/Helivanta tunnel origins
   use the other gateway Services; no repository reference uses `10.10.0.50`.
   The public custom-domain load balancer is still selected by active Gateways.
   Preserve it. The internal Service DNS remains available for later restore.
3. Migrate the Vertex apex and wildcard DNS A records to
   `199.36.153.8/30`. Retain PSC while clients migrate. After at least the 300-second
   DNS TTL, verify authenticated Vertex calls from current callers and absence of
   continued PSC use, then set `enable_vertex_psc=false` in a separate Git change
   and create a fresh retirement plan. Do not apply the retirement review plan
   before that verification. State moved blocks preserve both PSC resource
   identities during the migration.

## Verification and rollback

Helm renders, strict chart lints, locality/Valkey/waypoint tests, server-side
resource dry run and Terraform validation/mock-provider tests pass. The first Atlantis apply changed only three DNS resources, with no deletions.
The internal gateway now has zero replicas and a ClusterIP Service; GKE removed
its internal forwarding rule. The public forwarding rule remains. All checked
frontend and waypoint Services retain ready endpoints; no new application pod
became unready.

DNS migration applied at 04:39 UTC. After the 300-second TTL, all three DevAI
API pods resolved the apex/wildcard to the private VIPs and returned HTTP 200
for authenticated global locations, Gemini model metadata and regional model
listing, using their own Workload Identity and validated TLS. No PSC connections
were observed in these pods. Kora and Roamie agents also resolved the private VIPs.
The default PSC flag is now disabled for the separately reviewed retirement.

Waypoints already carried Istio's equivalent PreferClose default before this
change. Their explicit PreferSameZone annotation standardizes the preference;
no additional savings are attributed to changing that synonym. Listener
allowedRoutes explicitly matches the API server's Same-namespace default to
avoid GitOps drift. Shared application chart versions were bumped after CI
identified the missing version increments; repository tests passed.

Roll back locality hints by reverting their commit; ensure endpoint readiness
and routing remain healthy. Restore the unused gateway from the capture before
its rollout, enabling its previous HPA and LoadBalancer Service. Its old VIP may
need explicit allocation when restored; current consumers do not reference it.
While PSC is retained, rollback DNS with `vertex_dns_addresses=["10.255.0.2"]`.
After retirement, restore PSC first and verify it before changing DNS back.

Before approval/deletion, resource metadata is captured at
`/tmp/tesseract-cost-audit-20261004/remaining-network/` with restricted permissions.
These captures contain no secret payloads. Observe endpoints/ready pods and test
representative existing routes before/after each rollout. Compare full billing
usage days once export catches up; locality savings cannot be promised from
historical byte totals alone.

## Remaining larger choices

PostgreSQL traffic includes cross-zone replication and scheduled WAL archive
switches. Several low-write databases generate substantially more 16-MiB archive
capacity than actual WAL records. A longer archive timeout could reduce padding,
but it changes backup freshness in a complete cluster-loss scenario. No archive
cadence, database replica, disk, backup retention or availability setting is
changed by this patch. Any such change needs named targets and an explicit
recovery tradeoff.

The installed Percona MongoDB operator hardcodes a five-second reconciliation
interval. Its exposed RESYNC_PERIOD setting does not control that loop, so no
ineffective polling configuration was added.

Fixed CUD payments are the largest bill category and persist independently of
network savings. The flexible CUD exception request remains pending.

Existing Artifact Registry remote repositories already cover Docker Hub, GHCR,
Quay and registry.k8s.io. Some runtime images still reference upstream registries;
future mirror cutovers should preserve digests and be verified per workload.
No image changes or database rolling restarts are included in this patch.

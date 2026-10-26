# Rocket.Chat with restricted Zitadel access

Status: prepared; live rollout and user login acceptance pending.

Deploy Rocket.Chat 8.9.0 at https://rocketchat.tesserix.app in namespace `rocketchat`.
Upstream GitHub releases and the release-info endpoint identified 8.9.0 as the
latest stable release on 2026-10-26. Its exact image digest was verified by pulling
it. Use MongoDB 8.0.34, the current patch of the release's explicitly compatible
8.0 series, also pinned to its verified digest.

Initial sizing assumes two people, 5,000 notification messages/day averaging
2 KiB, bursts of 10 messages/second, and 10 MiB/day attachments. Message payloads
are about 3.7 GB/year, or 11 GB/three years, before indexes and metadata;
attachments add about 3.8 GB/year. Three MongoDB members each have a retained
20 GiB disk, plus a retained 20 GiB uploads disk. Growth requires disk expansion
or retention limits before reaching capacity. Requests total 5 GiB memory,
limits total 10 GiB. CPU requests follow the repository's memory-only convention.
80 GiB balanced persistent disk is approximately US$8/month before region/tax;
compute, snapshots and network charges depend on node headroom and backup design.
This is a planning estimate, not a billing quote.

Use one Rocket.Chat process and a three-member authenticated MongoDB replica set
spread over nodes. A single-process restart interrupts clients; this initial
workspace is not a highly available chat service. Pilot target: 99.5% monthly
availability, message acknowledgement p99 under 2 seconds. The intended recovery
target before notification cutover is RPO <=24 hours and RTO <=2 hours, to be
proven with off-cluster backup and an isolated restore. A replica set and retained
PVCs do not constitute a backup. FileSystem uploads constrain this deployment to
one app replica; horizontal scaling requires object storage and upstream-supported
multi-instance configuration.

Chat history, uploaded support material and integration credentials are the
assets. Internet visitors and other Zitadel users must not gain access. The
identity boundary is a dedicated restricted Zitadel project with exactly the two
verified accounts: samyak.rout@gmail.com and mahesh.sangawar@gmail.com. Both are
workspace admins, appropriate for the initial two-person operations team.
Public signup, anonymous access, password changes and password recovery are
disabled; no local bootstrap administrator is provisioned. SSO provisions accounts
using stable `sub` identities, without email-based account merging. Project
membership and role checks must be enabled before creating the confidential OIDC
client. No wildcard callback, generic Gmail-domain allowlist, or browser proxy is
used. The mobile app uses Rocket.Chat's own OAuth login flow.

Zitadel downtime prevents new sign-ins; existing Rocket.Chat sessions are separate
and may continue. Removing a member from Zitadel does not automatically revoke
Rocket.Chat sessions: deactivate the user and invalidate its sessions in
Rocket.Chat during offboarding. MongoDB quorum loss makes chat unavailable; the
app must reconnect when quorum returns. OpenBao/ESO failure prevents cold start
when secrets are absent; already running pods retain their environment values.
Push-gateway failure delays mobile notifications; browser access remains usable.

Credentials live under `rocketchat/prod/app/rocketchat-*` in OpenBao, through a
namespace-bound reader. Provisioning uses compare-and-set creation and readback;
it refuses different existing values and never rotates implicitly. Runtime secret
changes trigger a restart; explicit overwrite settings update the stored OAuth
credentials. Database and replica-key rotation require a coordinated database
procedure, not just replacing the Kubernetes secret.

Use GitOps and a manually synced application for the initial rollout. Database
schema upgrades require a pre-upgrade backup and tested restore; reverting the
image alone is not a safe database rollback. Preserve disks on application removal.

The simpler alternative of a single unauthenticated MongoDB was rejected because
it exposes data to lateral access and provides no election/failure tolerance.
An OAuth proxy was rejected because it can break native mobile APIs and sockets.
No Slack integrations are redirected in this change. Before migrating them, prove
backup/restore, both permitted logins, a denied third account, and mobile push.

Sources:
- https://github.com/RocketChat/Rocket.Chat/releases/tag/8.9.0
- https://releases.rocket.chat/8.9.0/info
- https://docs.rocket.chat/docs/system-requirements
- https://docs.rocket.chat/docs/push-notifications

Mobile push requires workspace registration and acceptance of Rocket.Chat's cloud
service privacy terms in the workspace UI. The 8.9 source marks custom OAuth as
requiring Premium starting with 9.0; review licensing before the next major upgrade.

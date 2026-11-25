# Yes Hospital synthetic IGST acceptance window

Status: prepared, not approved/applied. This is software acceptance in the shared
non-GA prod/QA environment; it authorizes no real dispensing, payment or legal
filing. General retail remains unreleased.

## Exact scope

- Application candidate: tesserix/helivanta#1852.
- Console candidate: tesserix/tesserix-home#677.
- Reusable chart support: #1724; activation: #1725.
- Approved-candidate chart source: `51683003f997ff5e98f39b2eda0232202ebd402c`.
- Tenant: Yes Hospital, `351d2d39-7a35-5d85-ab5d-bcd22bb0a18b`, resolved from
  the existing QA pharmacy ownership reference. Cross-check the signed-in tenant.
- Deadline: `2026-11-26T06:00:00Z`; never silently extend an expired window.

The policy only makes the seven compiled pharmacy pilot areas eligible for this
tenant's already authorized members. Console switches, dependency closure and
all product guards remain separate. Neither pharmacy ID nor outlet ID is a tenant
ID, and client-supplied headers never establish pilot membership.

## Readiness found on 25 November 2026

Read-only checks of the existing QA outlet found no licence, licence review,
licence evidence, tax registration or invoice profile. The outlet is not ready
for checkout. Do not represent its working low-stock page as financial acceptance.

Set up the labelled QA data through supported owner/reviewer APIs or UI before
attempting a post. Use conspicuous `TEST / NOT FOR DISPENSING` fixtures in the QA
outlet only. Synthetic documents and reviews are software test inputs, not proof
of real facility licensing or professional authority. Keep reviewer identity and
audit attribution distinct. Do not borrow a real person's tax identity, weaken
review controls or write business/projection tables directly to satisfy a guard.
Do not reuse the low-stock QA product for transactions.

## Execution after named rollout/activation approval

1. Deploy compatible Console and chart catalogue tooling; release the exact
   approved Helivanta revision through its protected Release/Kargo workflow.
2. Apply the reviewed API/GrowthBook chart pins and this tenant/deadline policy
   through GitOps. Verify exact images, policy rollout and application health.
3. Enable catalogue, stock, prescriptions, returns, reports, payables and counter
   in Console dependency order, with an attributable #1689 reason. Counter last.
4. Verify the signed-in Yes Hospital snapshot and an outside-tenant denial.
   Confirm the existing domain/outlet/permission failures remain enforced.
5. Complete QA setup/review, quote same-state and Maharashtra-to-Odisha cases,
   post the synthetic IGST sale, then reverse it through partial and final
   original-component credits. Preserve stable command references for retries.
6. Reconcile UI invoices, credits, daily/item reports and CSV. Require explicit
   IGST Tally mappings and balanced sale/credit vouchers; do not transmit the
   export into a real accounting system.
7. Capture totals, synthetic references, exact revisions and failures without
   credentials or personal data. End temporary QA grants and complete supported
   fixture reversals before disabling the pilot flags. Preserve history.

Expiry stops new admission and can close pilot-gated invoice reads; it does not
cancel already admitted work. If an outcome remains unresolved, preserve its
reference and recover through a separately approved window. Never replace the
command with a second transaction to mask an uncertain result.

The application policy and provider switches are independent. A green Console
switch alone is not proof that a tenant policy exists, a licence is valid, stock
is available or a workflow passed. Keep #1689 open until actual acceptance has
been recorded.

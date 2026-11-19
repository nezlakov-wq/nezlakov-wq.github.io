# Moonlit Chat — security audit work log

Date: 2026-11-19

## Confirmed issues fixed in production

### Group invitation privacy and capacity were enforced only by the frontend

**Affected RPC:** `public.add_conversation_member(uuid, uuid)`  
**Severity:** Medium (privacy-control bypass / resource-abuse vector)

The SECURITY DEFINER RPC checked that the caller was a member of a group, then inserted the requested user into `conversation_members`. It did not enforce the invited user's `profiles.hide_groups` preference or the group size limit (20 members for standard accounts, 50 for Plus).

**Change applied:** the database function now enforces both checks. It locks the conversation row while counting members so concurrent additions cannot race past the limit. Existing member additions remain idempotent. Channel membership behavior is intentionally unchanged.

**Production migration:** `enforce_group_invite_privacy_and_member_limits`  
**Applied:** 2026-11-19  
**Verified:** read back the deployed function definition and confirmed auth, membership, privacy, capacity and row-lock checks; migration is present in Supabase history.

### Concurrent inserts could race past quotas

**Affected controls:** group membership trigger, story daily quota trigger, pinned-chat RPC.  
**Severity:** Low–Medium (quota enforcement bypass under concurrent requests).

The previous trigger/RPC implementations counted current rows without serializing competing transactions. Concurrent inserts could both observe a count below the cap and both proceed.

**Change applied:** group membership trigger now locks the parent conversation before counting; story creation serializes per user with a transaction-scoped advisory lock; pinned-chat changes serialize per user before checking the 3/10 cap. Existing limits and user-facing behavior are preserved.

**Production migration:** `serialize_group_story_and_pinned_quotas`  
**Applied:** 2026-11-19  
**Verified:** read back all three function definitions, confirmed both triggers remain attached to their original tables, confirmed internal trigger functions remain non-executable by anon/authenticated, and confirmed `set_chat_pinned` remains executable by authenticated users and service_role.

### YooKassa checkout creation was not idempotent across repeated invocations

**Affected component:** `yookassa-create` Edge Function and checkout client.  
**Severity:** Medium (duplicate pending payment creation / user confusion; provider-side duplicate capture risk mitigated separately by settlement idempotency).

Previously, each invocation generated a fresh provider `Idempotence-Key`. Retrying the same checkout through a new invocation could therefore create a second payment.

**Change applied:** a private durable checkout-intent table stores a client idempotency UUID and a stable provider idempotency UUID. The reservation RPC applies the existing per-user rate limit only once per new intent, rejects key reuse for a different product, and returns the previously stored payment URL when available. The intent table has RLS enabled and no anon/authenticated table grants. The completion RPC atomically records the pending payment and links it to the intent. If a request is interrupted after YooKassa creates the payment but before the database records it, a retry with the same key reuses the same provider key. Unresolved intents older than 20 hours are refused rather than blindly retried beyond the provider's idempotency window.

The frontend now keeps a per-product attempt key in session storage for up to 10 minutes and clears it after returning from the provider. The Edge Function retains compatibility with older clients by generating a key when none is supplied.

**Production migrations:** `durable_yookassa_checkout_idempotency`, `enable_rls_on_private_checkout_intents`  
**Applied:** 2026-11-19  
**Edge Function:** `yookassa-create` deployed as version 12, JWT verification remains enabled.  
**Verified:** private intent table exists; both RPCs have empty search_path, are executable only by service_role (not anon/authenticated), and the deployed Edge Function source uses the reserve/complete RPCs and reuses the stored provider key.

**Not yet end-to-end tested:** live YooKassa sandbox scenarios for concurrent same-key requests, retry after provider success/database interruption, different-product key reuse rejection, and existing-payment URL replay. No real payment was initiated as part of this audit.

### Per-user report, appeal, and alias quotas could race under concurrent requests

**Affected RPCs:** `add_username`, `report_user`, `submit_appeal`.  
**Severity:** Low (business-rule/resource-abuse limits).

These functions checked per-user counts or existing rows without serializing concurrent calls. Multiple simultaneous requests could pass the same check before either transaction committed.

**Change applied:** transaction-scoped advisory locks now serialize alias creation per account, report submission per reporter/target pair, and appeal submission per account. Existing validations, return messages, and execute grants are preserved.

**Production migration:** `serialize_username_report_and_appeal_limits`  
**Applied:** 2026-11-19  
**Verified:** read back all three function definitions; `search_path` remains explicitly set, anon execution remains denied, and authenticated execution remains enabled as required by the client.

## Other reviewed areas (not claimed as fully audited)

- YooKassa webhook re-fetches payment/refund state from YooKassa and delegates settlement to a row-locked, service-role-only SQL function. Product/amount checks and duplicate-settlement handling are present in the inspected code.
- Storage policies reviewed for chat media, stories, report evidence, and avatars. The `avatars` bucket is public by configuration; avatar objects must therefore be treated as public, or delivery must be redesigned around signed/private URLs.
- The inspected chat rendering paths escape user-controlled text before HTML insertion; link preview destinations are restricted to HTTP(S), and preview metadata is escaped before rendering. This is code review, not browser-based XSS testing.
- TURN configuration and behavior were not changed.

## Deployment status

The five database migrations above are applied to the Supabase production database. The `yookassa-create` Edge Function is deployed as version 12. Database function definitions, grants, trigger attachment, and Edge Function source were read back and checked. The GitHub PR remains separate from deployment; no website deployment is claimed.
# Moonlit Chat — security audit work log

Date: 2026-11-19

## Confirmed issues fixed in production

### Group invitation privacy and capacity were enforced only by the frontend

**Affected RPC:** `public.add_conversation_member(uuid, uuid)`  
**Severity:** Medium (privacy-control bypass / resource-abuse vector)

The SECURITY DEFINER RPC checked that the caller was a member of a group, then inserted the requested user into `conversation_members`. It did not enforce either of the checks present in the web client: the invited user's `profiles.hide_groups` preference and the group size limit (20 members for standard accounts, 50 for Plus).

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
**Verified:** read back all three function definitions, confirmed both triggers remain attached to their original tables, confirmed internal trigger functions remain non-executable by anon/authenticated, and confirmed `set_chat_pinned` remains executable by authenticated users only (plus service_role).

**Not yet integration-tested:** quota boundary tests under concurrent authenticated requests. No live user, group, story, or pin data was modified for testing.

## Other reviewed areas (not claimed as fully audited)

- YooKassa creation uses a new random `Idempotence-Key` for every invocation. This does not deduplicate separate repeated invocations; the current three-attempt rate limit only reduces the impact. A durable checkout-intent idempotency design remains open.
- YooKassa webhook re-fetches payment/refund state from YooKassa and delegates settlement to a row-locked, service-role-only SQL function. Product/amount checks and duplicate-settlement handling are present in the inspected code.
- Storage policies reviewed for chat media, stories, report evidence, and avatars. The `avatars` bucket is public by configuration; avatar objects must therefore be treated as public, or delivery must be redesigned around signed/private URLs.
- The inspected chat rendering paths escape user-controlled text before HTML insertion; link preview destinations are restricted to HTTP(S), and preview metadata is escaped before rendering. This is code review, not browser-based XSS testing.
- TURN configuration and behavior were not changed.

## Deployment status

Both database migrations above are applied to the Supabase production database and verified by reading back deployed function definitions and migration history. This does not imply that the GitHub PR was merged or that a website deployment occurred.
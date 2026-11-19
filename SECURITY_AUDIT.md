# Moonlit Chat — security audit work log

Date: 2026-11-19

## Confirmed issue fixed in production

### Group invitation privacy and capacity were enforced only by the frontend

**Affected RPC:** `public.add_conversation_member(uuid, uuid)`  
**Severity:** Medium (privacy-control bypass / resource-abuse vector)

The SECURITY DEFINER RPC checked that the caller was a member of a group, then inserted the requested user into `conversation_members`. It did not enforce either of the checks present in the web client:

- the invited user's `profiles.hide_groups` preference;
- the group size limit (20 members for standard accounts, 50 for Plus).

Because the function is directly callable through PostgREST RPC by authenticated users, a caller could bypass the UI and invite a user who had disabled group invitations, or exceed the client-side membership cap.

**Change applied:** the database function now enforces both checks. It locks the conversation row while counting members so concurrent additions to the same group cannot race past the limit. Existing member additions remain idempotent. Channel membership behavior is intentionally unchanged.

**Production migration:** `enforce_group_invite_privacy_and_member_limits`  
**Applied:** 2026-11-19  
**Post-apply verification:** queried `pg_get_functiondef('public.add_conversation_member(uuid,uuid)')` and confirmed the deployed definition contains authentication, group membership, hide_groups, member-limit, and row-lock checks. Confirmed the migration is recorded in Supabase migration history.

**Not yet integration-tested:** standard 19→20 / 20→21, Plus 49→50 / 50→51, target hide_groups=true rejection, duplicate no-op, and channel behavior. These require authenticated test accounts and representative test groups; no live user/group data was modified for testing.

## Other reviewed areas (not claimed as fully audited)

- YooKassa creation uses a new random `Idempotence-Key` for every invocation. This does not deduplicate separate repeated invocations; the current three-attempt rate limit only reduces the impact. A durable checkout-intent idempotency design remains open.
- YooKassa webhook re-fetches payment/refund state from YooKassa and delegates settlement to a row-locked, service-role-only SQL function. Product/amount checks and duplicate-settlement handling are present in the inspected code.
- Storage policies reviewed for chat media, stories, report evidence, and avatars. The `avatars` bucket is public by configuration; that is incompatible with treating avatar URLs as confidential, so the product must regard avatar objects as public or move to a signed/private delivery design.
- The inspected chat rendering paths escape user-controlled text before HTML insertion; link preview destinations are restricted to HTTP(S), and preview metadata is escaped before rendering. This is a code review, not a browser-based XSS test.
- TURN configuration and behavior were not changed.

## Deployment status

The group-invitation database hardening is applied to the Supabase production database and verified by reading back the deployed function definition. This does not imply that the GitHub PR was merged or that a website deployment occurred.
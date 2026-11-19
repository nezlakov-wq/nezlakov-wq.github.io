# Moonlit Chat — security audit work log

Date: 2026-11-19

## Confirmed issue addressed in this PR

### Group invitation privacy and capacity were enforced only by the frontend

**Affected RPC:** `public.add_conversation_member(uuid, uuid)`  
**Severity:** Medium (privacy-control bypass / resource-abuse vector)

The SECURITY DEFINER RPC checked that the caller was a member of a group, then inserted the requested user into `conversation_members`. It did not enforce either of the checks present in the web client:

- the invited user's `profiles.hide_groups` preference;
- the group size limit (20 members for standard accounts, 50 for Plus).

Because the function is directly callable through PostgREST RPC by authenticated users, a caller could bypass the UI and invite a user who had disabled group invitations, or exceed the client-side membership cap.

**Change:** the migration moves both checks into the SECURITY DEFINER function. It locks the conversation row while counting members so concurrent additions to the same group cannot race past the limit. Existing member additions remain idempotent. Channel membership behavior is intentionally unchanged.

**Validation performed:** reviewed the deployed function definition, the `conversation_members` RLS policies, the `profiles.hide_groups` column, the `is_plus(uuid)` helper, and the corresponding frontend checks in `index.html`.

**Still required before production application:**
- apply the migration in a non-production Supabase branch or staging database;
- test a standard account at 19/20 members and confirm the 21st member is rejected;
- test a Plus account at 49/50 members and confirm the 51st member is rejected;
- verify an invite to a user with `hide_groups = true` is rejected;
- verify ordinary group additions, duplicate additions, and channel behavior remain unchanged.

## Other reviewed areas (not claimed as fully audited)

- YooKassa creation uses a new random `Idempotence-Key` for every invocation. This does not deduplicate separate repeated invocations; the current three-attempt rate limit only reduces the impact. A durable checkout-intent idempotency design remains open.
- YooKassa webhook re-fetches payment/refund state from YooKassa and delegates settlement to a row-locked, service-role-only SQL function. Product/amount checks and duplicate-settlement handling are present in the inspected code.
- Storage policies reviewed for chat media, stories, report evidence, and avatars. The `avatars` bucket is public by configuration; that is incompatible with treating avatar URLs as confidential, so the product must regard avatar objects as public or move to a signed/private delivery design.
- The inspected chat rendering paths escape user-controlled text before HTML insertion; link preview destinations are restricted to HTTP(S), and preview metadata is escaped before rendering. This is a code review, not a browser-based XSS test.
- TURN configuration and behavior were not changed.

## Deployment status

This PR contains a migration proposal only. It has not been applied to the production database, and merging this PR would not itself prove that the migration or website has been deployed.

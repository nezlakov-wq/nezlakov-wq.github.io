-- Enforce group invitation privacy and capacity in the database.
-- The frontend already checks hide_groups and the 20/50 member limits, but
-- SECURITY DEFINER allowed direct RPC callers to bypass those checks.
CREATE OR REPLACE FUNCTION public.add_conversation_member(conv uuid, member uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_is_group boolean;
  v_is_channel boolean;
  v_member_limit integer;
  v_member_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  IF member IS NULL THEN
    RAISE EXCEPTION 'member is required';
  END IF;

  -- Serialize additions to this conversation so concurrent requests cannot
  -- race past the member limit.
  SELECT c.is_group, c.is_channel
    INTO v_is_group, v_is_channel
  FROM public.conversations AS c
  WHERE c.id = conv
  FOR UPDATE;

  IF NOT FOUND OR NOT coalesce(v_is_group, false) THEN
    RAISE EXCEPTION 'group not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.conversation_members AS cm
    WHERE cm.conversation_id = conv
      AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'only members of a group can add members';
  END IF;

  -- Preserve the existing idempotent behavior for already-added members.
  IF EXISTS (
    SELECT 1
    FROM public.conversation_members AS cm
    WHERE cm.conversation_id = conv
      AND cm.user_id = member
  ) THEN
    RETURN;
  END IF;

  -- "Invitations to groups: Nobody" is a server-enforced privacy setting,
  -- not merely a client-side UI preference. Channels are not group invites.
  IF NOT coalesce(v_is_channel, false)
     AND EXISTS (
       SELECT 1
       FROM public.profiles AS p
       WHERE p.id = member
         AND p.hide_groups = true
     ) THEN
    RAISE EXCEPTION 'this user does not accept group invitations';
  END IF;

  -- Keep the same limits as the UI: 20 for standard accounts, 50 for Plus.
  -- Channels retain their existing membership behavior.
  IF NOT coalesce(v_is_channel, false) THEN
    v_member_limit := CASE
      WHEN public.is_plus(auth.uid()) THEN 50
      ELSE 20
    END;

    SELECT count(*)::integer
      INTO v_member_count
    FROM public.conversation_members AS cm
    WHERE cm.conversation_id = conv;

    IF v_member_count >= v_member_limit THEN
      RAISE EXCEPTION 'group member limit reached (% members)', v_member_limit;
    END IF;
  END IF;

  INSERT INTO public.conversation_members (conversation_id, user_id)
  VALUES (conv, member)
  ON CONFLICT (conversation_id, user_id) DO NOTHING;
END;
$function$;

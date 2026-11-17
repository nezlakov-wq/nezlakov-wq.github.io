CREATE OR REPLACE FUNCTION public.set_pinned(conv uuid, msg uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.conversation_members AS m
    WHERE m.conversation_id = conv
      AND m.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not a member';
  END IF;

  -- A conversation may only pin one of its own messages.
  IF msg IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.messages AS pinned
    WHERE pinned.id = msg
      AND pinned.conversation_id = conv
  ) THEN
    RAISE EXCEPTION 'message does not belong to this conversation';
  END IF;

  UPDATE public.conversations
  SET pinned_msg = msg
  WHERE id = conv;
END
$function$;

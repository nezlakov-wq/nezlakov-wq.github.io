CREATE OR REPLACE FUNCTION public.set_chat_ttl(conv uuid, secs integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  g boolean;
  ch boolean;
  owner uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;
  IF secs IS NULL OR secs NOT IN (0, 3600, 86400, 604800) THEN
    RAISE EXCEPTION 'Недопустимый срок хранения';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.conversation_members
    WHERE conversation_id = conv AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not a member';
  END IF;
  SELECT is_group, is_channel, created_by
    INTO g, ch, owner
  FROM public.conversations
  WHERE id = conv;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Чат не найден';
  END IF;
  IF (coalesce(g, false) OR coalesce(ch, false)) AND owner <> auth.uid() THEN
    RAISE EXCEPTION 'Срок хранения задаёт только создатель группы или канала';
  END IF;
  UPDATE public.conversations
  SET ttl_seconds = nullif(secs, 0)
  WHERE id = conv;
END;
$function$;

CREATE OR REPLACE FUNCTION public.purge_expired(conv uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t integer;
  g boolean;
  ch boolean;
  owner uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.conversation_members
    WHERE conversation_id = conv AND user_id = auth.uid()
  ) THEN
    RETURN;
  END IF;
  SELECT ttl_seconds, is_group, is_channel, created_by
    INTO t, g, ch, owner
  FROM public.conversations
  WHERE id = conv;
  IF NOT FOUND OR t IS NULL OR t NOT IN (3600, 86400, 604800) THEN
    RETURN;
  END IF;
  IF (coalesce(g, false) OR coalesce(ch, false)) AND owner <> auth.uid() THEN
    RETURN;
  END IF;
  DELETE FROM public.messages
  WHERE conversation_id = conv
    AND created_at < now() - make_interval(secs => t);
END;
$function$;

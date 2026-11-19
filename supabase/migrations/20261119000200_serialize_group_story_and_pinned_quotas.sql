-- Serialize trigger-enforced quotas to prevent concurrent requests racing past limits.

CREATE OR REPLACE FUNCTION public.check_group_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  lim integer := 20;
  creator uuid;
  is_group_chat boolean;
BEGIN
  SELECT c.is_group, c.created_by
    INTO is_group_chat, creator
  FROM public.conversations AS c
  WHERE c.id = NEW.conversation_id
  FOR UPDATE;

  IF coalesce(is_group_chat, false) THEN
    IF public.is_plus(creator) THEN
      lim := 50;
    END IF;

    IF (
      SELECT count(*)
      FROM public.conversation_members AS m
      WHERE m.conversation_id = NEW.conversation_id
    ) >= lim THEN
      RAISE EXCEPTION 'В группе не больше % участников', lim;
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION public.check_story_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  lim integer := 5;
  cnt integer;
BEGIN
  IF NEW.user_id IS NULL THEN
    RAISE EXCEPTION 'user required';
  END IF;

  PERFORM pg_advisory_xact_lock(183601, hashtext(NEW.user_id::text));

  IF public.is_plus(NEW.user_id) THEN
    lim := 10;
  END IF;

  SELECT count(*)
    INTO cnt
  FROM public.stories
  WHERE user_id = NEW.user_id
    AND created_at > now() - interval '24 hours';

  IF cnt >= lim THEN
    RAISE EXCEPTION 'Нельзя больше % историй в сутки', lim;
  END IF;

  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION public.set_chat_pinned(conv uuid, val boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  lim integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  PERFORM pg_advisory_xact_lock(183602, hashtext(auth.uid()::text));

  lim := CASE WHEN public.is_plus(auth.uid()) THEN 10 ELSE 3 END;

  IF val AND (
    SELECT count(*)
    FROM public.conversation_members
    WHERE user_id = auth.uid() AND pinned
  ) >= lim THEN
    RAISE EXCEPTION 'Не больше % закреплённых чатов', lim;
  END IF;

  UPDATE public.conversation_members
  SET pinned = val
  WHERE conversation_id = conv
    AND user_id = auth.uid();
END
$function$;
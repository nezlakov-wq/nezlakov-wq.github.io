ALTER TABLE public.messages
  ADD CONSTRAINT messages_text_max_64k
    CHECK (octet_length(text) <= 65536),
  ADD CONSTRAINT messages_kind_allowed
    CHECK (kind IS NULL OR kind IN ('voice', 'call')),
  ADD CONSTRAINT messages_key_version_nonnegative
    CHECK (key_version >= 0);

CREATE OR REPLACE FUNCTION public.guard_message_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  is_grp boolean;
  other uuid;
BEGIN
  IF NEW.text IS NULL OR octet_length(NEW.text) > 65536 THEN
    RAISE EXCEPTION 'message payload too large';
  END IF;
  IF NEW.key_version < 0 THEN
    RAISE EXCEPTION 'invalid key version';
  END IF;
  IF NEW.kind IS NOT NULL AND NEW.kind NOT IN ('voice', 'call') THEN
    RAISE EXCEPTION 'invalid message kind';
  END IF;
  IF NEW.reply_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.messages replied
    WHERE replied.id = NEW.reply_to
      AND replied.conversation_id = NEW.conversation_id
  ) THEN
    RAISE EXCEPTION 'reply target must be in the same conversation';
  END IF;

  IF NEW.kind = 'voice' THEN
    SELECT is_group INTO is_grp
    FROM public.conversations
    WHERE id = NEW.conversation_id;
    IF NOT coalesce(is_grp, false) THEN
      SELECT user_id INTO other
      FROM public.conversation_members
      WHERE conversation_id = NEW.conversation_id
        AND user_id <> NEW.sender_id
      LIMIT 1;
      IF other IS NOT NULL AND public.privacy_blocks(other, 'hide_voice') THEN
        RAISE EXCEPTION 'Собеседник не принимает голосовые сообщения';
      END IF;
    END IF;
  END IF;

  IF NEW.forwarded_from IS NOT NULL AND NEW.forwarded_from <> NEW.sender_id
     AND public.privacy_blocks(NEW.forwarded_from, 'hide_forward') THEN
    RAISE EXCEPTION 'Автор запретил пересылать его сообщения';
  END IF;
  RETURN NEW;
END
$function$;

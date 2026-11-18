CREATE OR REPLACE FUNCTION public.toggle_reaction(msg uuid, emoji text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  cur jsonb;
  users jsonb;
  uid text := auth.uid()::text;
  allowed_emojis text[] := ARRAY[
    '😀','😂','😍','🥰','😎','🤔','😢','😡','👍','👎','👏','🙏',
    '🔥','❤️','💯','🎉','😘','😉','🤣','😅','😇','🤗','😴','🙄',
    '😱','🥳','👋','💪','🤝','✅','❌','⭐','🌙','☀️','🍕','☕',
    '🎁','🐱','🐶','🌹','💔','😋','🤩','😏','🫶'
  ];
BEGIN
  IF emoji IS NULL OR NOT (emoji = ANY(allowed_emojis)) THEN
    RAISE EXCEPTION 'Invalid reaction';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.messages AS m
    JOIN public.conversation_members AS cm
      ON cm.conversation_id = m.conversation_id
    WHERE m.id = msg
      AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT reactions INTO cur
  FROM public.messages
  WHERE id = msg;

  users := coalesce(cur -> emoji, '[]'::jsonb);

  IF users ? uid THEN
    users := (
      SELECT coalesce(jsonb_agg(v), '[]'::jsonb)
      FROM jsonb_array_elements(users) v
      WHERE v <> to_jsonb(uid)
    );
  ELSE
    users := users || to_jsonb(uid);
  END IF;

  IF jsonb_array_length(users) = 0 THEN
    cur := cur - emoji;
  ELSE
    cur := jsonb_set(cur, ARRAY[emoji], users, true);
  END IF;

  UPDATE public.messages
  SET reactions = cur
  WHERE id = msg;
END
$function$;

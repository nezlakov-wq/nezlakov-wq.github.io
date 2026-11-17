-- Bound RPC batch sizes and ensure sync_message_wraps changes only key wrappers.
CREATE OR REPLACE FUNCTION public.sync_group_keys(items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  me uuid := auth.uid();
  it jsonb;
  cid uuid;
  did text;
  done integer := 0;
BEGIN
  IF me IS NULL THEN RAISE EXCEPTION 'Нужен вход'; END IF;
  IF jsonb_typeof(items) IS DISTINCT FROM 'array' OR jsonb_array_length(items) > 100 THEN
    RAISE EXCEPTION 'Неверный пакет ключей';
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(items) LOOP
    cid := (it->>'conversation_id')::uuid;
    did := it->>'device_id';
    IF did IS NULL THEN CONTINUE; END IF;
    IF length(did) > 128 OR (it->>'key_version')::int <= 0 THEN
      RAISE EXCEPTION 'Неверные параметры ключа';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.conversation_members cm
      WHERE cm.conversation_id = cid AND cm.user_id = me
    ) THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.user_devices d
      WHERE d.user_id = me AND d.device_id = did
    ) THEN RAISE EXCEPTION 'Устройство не найдено'; END IF;
    IF left(coalesce(it->>'wrapped', ''), 3) <> 'g1:'
       OR length(it->>'wrapped') > 16384 THEN
      RAISE EXCEPTION 'Неверный формат ключа';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.group_keys g
      WHERE g.conversation_id = cid
        AND g.key_version = (it->>'key_version')::int
        AND g.user_id = me AND g.device_id = did
    ) THEN CONTINUE; END IF;
    INSERT INTO public.group_keys (conversation_id, key_version, user_id, device_id, wrapped)
    VALUES (cid, (it->>'key_version')::int, me, did, it->>'wrapped');
    done := done + 1;
  END LOOP;
  RETURN done;
END
$function$;

CREATE OR REPLACE FUNCTION public.sync_message_wraps(items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  me uuid := auth.uid();
  it jsonb;
  m record;
  old_body jsonb;
  new_body jsonb;
  x jsonb;
  done integer := 0;
BEGIN
  IF me IS NULL THEN RAISE EXCEPTION 'Недоступно'; END IF;
  IF jsonb_typeof(items) IS DISTINCT FROM 'array' OR jsonb_array_length(items) > 100 THEN
    RAISE EXCEPTION 'Неверный пакет обёрток';
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(items) LOOP
    SELECT id, conversation_id, text INTO m
    FROM public.messages WHERE id = (it->>'id')::uuid;
    IF NOT FOUND THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.conversation_members cm
      WHERE cm.conversation_id = m.conversation_id AND cm.user_id = me
    ) THEN CONTINUE; END IF;
    IF m.text IS NULL OR left(m.text, 3) <> 'e2:' OR left(it->>'text', 3) <> 'e2:' THEN CONTINUE; END IF;

    old_body := convert_from(decode(substr(m.text, 4), 'base64'), 'UTF8')::jsonb;
    new_body := convert_from(decode(substr(it->>'text', 4), 'base64'), 'UTF8')::jsonb;

    IF jsonb_typeof(old_body) IS DISTINCT FROM 'object'
       OR jsonb_typeof(new_body) IS DISTINCT FROM 'object'
       OR jsonb_typeof(old_body->'k') IS DISTINCT FROM 'array'
       OR jsonb_typeof(new_body->'k') IS DISTINCT FROM 'array' THEN
      CONTINUE;
    END IF;

    -- Preserve every payload field except the recipient-key array.
    IF old_body - 'k' IS DISTINCT FROM new_body - 'k' THEN CONTINUE; END IF;
    IF jsonb_array_length(new_body->'k') > jsonb_array_length(old_body->'k') + 100 THEN
      RAISE EXCEPTION 'Слишком много обёрток';
    END IF;

    -- Every existing wrapper must remain unchanged.
    IF (
      SELECT count(*) FROM jsonb_array_elements(old_body->'k') o
      WHERE EXISTS (
        SELECT 1 FROM jsonb_array_elements(new_body->'k') n WHERE n = o
      )
    ) <> jsonb_array_length(old_body->'k') THEN
      CONTINUE;
    END IF;

    -- Added wrappers may target only the caller's registered devices.
    FOR x IN SELECT * FROM jsonb_array_elements(new_body->'k') LOOP
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(old_body->'k') o WHERE o = x) THEN
        CONTINUE;
      END IF;
      IF (x->>'u')::uuid IS DISTINCT FROM me THEN
        RAISE EXCEPTION 'Чужая обёртка';
      END IF;
      IF length(x->>'d') > 128 OR NOT EXISTS (
        SELECT 1 FROM public.user_devices d
        WHERE d.user_id = me AND d.device_id = x->>'d'
      ) THEN
        RAISE EXCEPTION 'Устройство не найдено';
      END IF;
    END LOOP;

    UPDATE public.messages SET text = it->>'text' WHERE id = m.id;
    done := done + 1;
  END LOOP;
  RETURN done;
END
$function$;
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
  kv integer;
  wrapped_value text;
  done integer := 0;
BEGIN
  IF me IS NULL THEN RAISE EXCEPTION 'Нужен вход'; END IF;
  IF jsonb_typeof(items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Неверный пакет ключей';
  END IF;
  IF jsonb_array_length(items) > 100 THEN
    RAISE EXCEPTION 'Неверный пакет ключей';
  END IF;

  FOR it IN SELECT value FROM jsonb_array_elements(items) AS e(value) LOOP
    IF jsonb_typeof(it) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Неверный элемент ключа';
    END IF;
    cid := (it->>'conversation_id')::uuid;
    did := it->>'device_id';
    kv := (it->>'key_version')::integer;
    wrapped_value := it->>'wrapped';

    IF did IS NULL THEN CONTINUE; END IF;
    IF did = '' OR length(did) > 128 OR kv IS NULL OR kv <= 0 THEN
      RAISE EXCEPTION 'Неверные параметры ключа';
    END IF;
    IF wrapped_value IS NULL OR length(wrapped_value) <= 3
       OR length(wrapped_value) > 16384 OR left(wrapped_value, 3) <> 'g1:' THEN
      RAISE EXCEPTION 'Неверный формат ключа';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.conversation_members cm
      WHERE cm.conversation_id = cid AND cm.user_id = me
    ) THEN CONTINUE; END IF;
    -- This SECURITY DEFINER RPC bypasses the table's RLS insert policy.
    -- Match that policy's group-only restriction explicitly.
    IF NOT EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = cid AND c.is_group AND NOT c.is_channel
    ) THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.user_devices d
      WHERE d.user_id = me AND d.device_id = did
    ) THEN RAISE EXCEPTION 'Устройство не найдено'; END IF;

    IF EXISTS (
      SELECT 1 FROM public.group_keys g
      WHERE g.conversation_id = cid AND g.key_version = kv
        AND g.user_id = me AND g.device_id = did
    ) THEN CONTINUE; END IF;

    INSERT INTO public.group_keys (conversation_id, key_version, user_id, device_id, wrapped)
    VALUES (cid, kv, me, did, wrapped_value);
    done := done + 1;
  END LOOP;
  RETURN done;
END
$function$;

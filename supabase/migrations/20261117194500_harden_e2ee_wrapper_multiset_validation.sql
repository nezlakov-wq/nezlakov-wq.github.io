-- Harden E2EE sync inputs and preserve the exact multiset of existing wrappers.
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
  IF jsonb_typeof(items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Неверный пакет обёрток';
  END IF;
  IF jsonb_array_length(items) > 100 THEN
    RAISE EXCEPTION 'Неверный пакет обёрток';
  END IF;

  FOR it IN SELECT value FROM jsonb_array_elements(items) AS e(value) LOOP
    IF jsonb_typeof(it) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Неверный элемент обёртки';
    END IF;

    SELECT id, conversation_id, text INTO m
    FROM public.messages WHERE id = (it->>'id')::uuid
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.conversation_members cm
      WHERE cm.conversation_id = m.conversation_id AND cm.user_id = me
    ) THEN CONTINUE; END IF;

    IF m.text IS NULL OR left(m.text, 3) <> 'e2:'
       OR it->>'text' IS NULL OR left(it->>'text', 3) <> 'e2:' THEN
      CONTINUE;
    END IF;

    old_body := convert_from(decode(substr(m.text, 4), 'base64'), 'UTF8')::jsonb;
    new_body := convert_from(decode(substr(it->>'text', 4), 'base64'), 'UTF8')::jsonb;

    IF jsonb_typeof(old_body) IS DISTINCT FROM 'object'
       OR jsonb_typeof(new_body) IS DISTINCT FROM 'object'
       OR jsonb_typeof(old_body->'k') IS DISTINCT FROM 'array'
       OR jsonb_typeof(new_body->'k') IS DISTINCT FROM 'array' THEN
      CONTINUE;
    END IF;

    IF old_body - 'k' IS DISTINCT FROM new_body - 'k' THEN CONTINUE; END IF;
    IF jsonb_array_length(old_body->'k') > 512
       OR jsonb_array_length(new_body->'k') > jsonb_array_length(old_body->'k') + 100 THEN
      RAISE EXCEPTION 'Слишком много обёрток';
    END IF;

    -- Preserve every old wrapper including duplicate multiplicity.
    IF EXISTS (
      SELECT 1
      FROM (
        SELECT value, count(*) AS n
        FROM jsonb_array_elements(old_body->'k') AS o(value)
        GROUP BY value
      ) oldw
      LEFT JOIN (
        SELECT value, count(*) AS n
        FROM jsonb_array_elements(new_body->'k') AS n(value)
        GROUP BY value
      ) neww USING (value)
      WHERE coalesce(neww.n, 0) < oldw.n
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(new_body->'k') AS w(value)
      GROUP BY value->>'u', value->>'d'
      HAVING count(*) > 1
    ) THEN
      RAISE EXCEPTION 'Повторная обёртка устройства';
    END IF;

    FOR x IN
      SELECT added.value
      FROM (
        SELECT ranked.value, ranked.rn
        FROM (
          SELECT n.value,
                 row_number() OVER (PARTITION BY n.value ORDER BY n.ord) AS rn
          FROM jsonb_array_elements(new_body->'k') WITH ORDINALITY AS n(value, ord)
        ) ranked
      ) added
      WHERE added.rn > (
        SELECT count(*)
        FROM jsonb_array_elements(old_body->'k') AS o(value)
        WHERE o.value = added.value
      )
    LOOP
      IF jsonb_typeof(x) IS DISTINCT FROM 'object'
         OR NOT (x ?& ARRAY['u','d','e','i','w'])
         OR (x - 'u' - 'd' - 'e' - 'i' - 'w') <> '{}'::jsonb
         OR jsonb_typeof(x->'u') IS DISTINCT FROM 'string'
         OR jsonb_typeof(x->'d') IS DISTINCT FROM 'string'
         OR jsonb_typeof(x->'e') IS DISTINCT FROM 'object'
         OR jsonb_typeof(x->'i') IS DISTINCT FROM 'string'
         OR jsonb_typeof(x->'w') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Неверная структура обёртки';
      END IF;

      IF (x->>'u')::uuid IS DISTINCT FROM me THEN
        RAISE EXCEPTION 'Чужая обёртка';
      END IF;
      IF coalesce(x->>'d', '') = '' OR length(x->>'d') > 128
         OR x->'e'->>'kty' <> 'EC'
         OR x->'e'->>'crv' IS DISTINCT FROM 'P-256'
         OR coalesce(x->'e'->>'x', '') = ''
         OR coalesce(x->'e'->>'y', '') = ''
         OR length(x->'e'->>'x') > 128
         OR length(x->'e'->>'y') > 128
         OR (x->'e') ? 'd'
         OR length(x->>'i') < 8 OR length(x->>'i') > 64
         OR length(x->>'w') < 16 OR length(x->>'w') > 4096 THEN
        RAISE EXCEPTION 'Неверные параметры обёртки';
      END IF;

      IF NOT EXISTS (
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

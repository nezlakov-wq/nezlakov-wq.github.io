CREATE TABLE private.preview_rate_limits (
  user_id uuid PRIMARY KEY,
  window_started_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_attempt_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.preview_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.preview_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.preview_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION public.reserve_preview_slot(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  started_at timestamptz;
  used_attempts integer;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user required';
  END IF;

  INSERT INTO private.preview_rate_limits (user_id, window_started_at, attempts, last_attempt_at)
  VALUES (p_user_id, now(), 0, now())
  ON CONFLICT (user_id) DO NOTHING;

  SELECT window_started_at, attempts
    INTO started_at, used_attempts
  FROM private.preview_rate_limits
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF started_at <= now() - interval '5 minutes' THEN
    UPDATE private.preview_rate_limits
    SET window_started_at = now(), attempts = 1, last_attempt_at = now()
    WHERE user_id = p_user_id;
    RETURN true;
  END IF;

  IF used_attempts >= 60 THEN
    RETURN false;
  END IF;

  UPDATE private.preview_rate_limits
  SET attempts = attempts + 1, last_attempt_at = now()
  WHERE user_id = p_user_id;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_preview_slot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_preview_slot(uuid) TO service_role;

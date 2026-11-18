CREATE TABLE private.username_check_rate_limits (
  ip_hash text PRIMARY KEY CHECK (length(ip_hash) = 64 AND ip_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_attempt_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX username_check_rate_limits_last_attempt_idx
  ON private.username_check_rate_limits(last_attempt_at);

ALTER TABLE private.username_check_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.username_check_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.username_check_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION public.reserve_username_check_slot(p_ip_hash text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  started_at timestamptz;
  used_attempts integer;
BEGIN
  IF p_ip_hash IS NULL OR length(p_ip_hash) <> 64 OR p_ip_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid rate limit key';
  END IF;

  IF pg_try_advisory_xact_lock(783210009) THEN
    DELETE FROM private.username_check_rate_limits
    WHERE last_attempt_at < now() - interval '1 day';
  END IF;

  INSERT INTO private.username_check_rate_limits(ip_hash,window_started_at,attempts,last_attempt_at)
  VALUES(p_ip_hash,now(),0,now())
  ON CONFLICT(ip_hash) DO NOTHING;

  SELECT window_started_at,attempts INTO started_at,used_attempts
  FROM private.username_check_rate_limits
  WHERE ip_hash=p_ip_hash
  FOR UPDATE;

  IF started_at <= now() - interval '10 minutes' THEN
    UPDATE private.username_check_rate_limits
    SET window_started_at=now(),attempts=1,last_attempt_at=now()
    WHERE ip_hash=p_ip_hash;
    RETURN true;
  END IF;

  IF used_attempts >= 30 THEN
    RETURN false;
  END IF;

  UPDATE private.username_check_rate_limits
  SET attempts=attempts+1,last_attempt_at=now()
  WHERE ip_hash=p_ip_hash;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_username_check_slot(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_username_check_slot(text) TO service_role;

CREATE OR REPLACE FUNCTION public.username_is_taken(requested_username text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS(
    SELECT 1 FROM public.profiles p
    WHERE lower(p.username)=lower(requested_username)
  );
$function$;

REVOKE ALL ON FUNCTION public.username_is_taken(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.username_is_taken(text) TO service_role;

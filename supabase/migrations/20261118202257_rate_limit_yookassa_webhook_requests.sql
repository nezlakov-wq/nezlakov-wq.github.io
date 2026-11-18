CREATE TABLE private.yookassa_webhook_rate_limits (
  ip_hash text PRIMARY KEY CHECK (length(ip_hash) = 64 AND ip_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_attempt_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.yookassa_webhook_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.yookassa_webhook_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.yookassa_webhook_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION public.reserve_yookassa_webhook_slot(p_ip_hash text)
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

  INSERT INTO private.yookassa_webhook_rate_limits (ip_hash, window_started_at, attempts, last_attempt_at)
  VALUES (p_ip_hash, now(), 0, now())
  ON CONFLICT (ip_hash) DO NOTHING;

  SELECT window_started_at, attempts
    INTO started_at, used_attempts
  FROM private.yookassa_webhook_rate_limits
  WHERE ip_hash = p_ip_hash
  FOR UPDATE;

  IF started_at <= now() - interval '5 minutes' THEN
    UPDATE private.yookassa_webhook_rate_limits
    SET window_started_at = now(), attempts = 1, last_attempt_at = now()
    WHERE ip_hash = p_ip_hash;
    RETURN true;
  END IF;

  IF used_attempts >= 120 THEN
    RETURN false;
  END IF;

  UPDATE private.yookassa_webhook_rate_limits
  SET attempts = attempts + 1, last_attempt_at = now()
  WHERE ip_hash = p_ip_hash;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_yookassa_webhook_slot(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_yookassa_webhook_slot(text) TO service_role;

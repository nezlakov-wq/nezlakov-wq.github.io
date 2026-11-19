-- Durable checkout intent idempotency for repeated client requests.
CREATE TABLE IF NOT EXISTS private.yookassa_checkout_intents (
  user_id uuid NOT NULL,
  idempotency_key uuid NOT NULL,
  product text NOT NULL,
  provider_key uuid NOT NULL DEFAULT gen_random_uuid(),
  payment_id text,
  confirmation_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, idempotency_key)
);

REVOKE ALL ON TABLE private.yookassa_checkout_intents FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE private.yookassa_checkout_intents TO service_role;

CREATE OR REPLACE FUNCTION public.reserve_yookassa_checkout(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_product text
)
RETURNS TABLE (allowed boolean, expired boolean, provider_key uuid, payment_id text, confirmation_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_new boolean := false;
  v_started_at timestamptz;
  v_attempts integer;
  v_intent private.yookassa_checkout_intents%ROWTYPE;
BEGIN
  IF coalesce(auth.jwt()->>'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'service role required';
  END IF;
  IF p_user_id IS NULL OR p_idempotency_key IS NULL
     OR p_product NOT IN ('plus_month','plus_3m','plus_12m',
                          'tokens_50','tokens_100','tokens_200','tokens_500','tokens_1000') THEN
    RAISE EXCEPTION 'invalid checkout intent';
  END IF;

  INSERT INTO private.yookassa_checkout_intents(user_id,idempotency_key,product)
  VALUES (p_user_id,p_idempotency_key,p_product)
  ON CONFLICT (user_id,idempotency_key) DO NOTHING
  RETURNING true INTO v_new;

  SELECT * INTO v_intent
  FROM private.yookassa_checkout_intents
  WHERE user_id = p_user_id AND idempotency_key = p_idempotency_key
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'checkout intent unavailable';
  END IF;
  IF v_intent.product IS DISTINCT FROM p_product THEN
    RAISE EXCEPTION 'idempotency key already used for another product';
  END IF;

  IF coalesce(v_new,false) THEN
    INSERT INTO private.yookassa_payment_rate_limits(user_id,window_started_at,attempts,last_attempt_at)
    VALUES (p_user_id,now(),0,now())
    ON CONFLICT (user_id) DO NOTHING;

    SELECT window_started_at,attempts
      INTO v_started_at,v_attempts
    FROM private.yookassa_payment_rate_limits
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_started_at <= now() - interval '15 minutes' THEN
      UPDATE private.yookassa_payment_rate_limits
      SET window_started_at=now(),attempts=1,last_attempt_at=now()
      WHERE user_id=p_user_id;
    ELSIF v_attempts >= 3 THEN
      DELETE FROM private.yookassa_checkout_intents
      WHERE user_id=p_user_id AND idempotency_key=p_idempotency_key;
      RETURN QUERY SELECT false,false,NULL::uuid,NULL::text,NULL::text;
      RETURN;
    ELSE
      UPDATE private.yookassa_payment_rate_limits
      SET attempts=attempts+1,last_attempt_at=now()
      WHERE user_id=p_user_id;
    END IF;
  END IF;

  IF v_intent.payment_id IS NULL AND v_intent.created_at < now() - interval '20 hours' THEN
    RETURN QUERY SELECT true,true,v_intent.provider_key,NULL::text,NULL::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT true,false,v_intent.provider_key,v_intent.payment_id,v_intent.confirmation_url;
END
$function$;

CREATE OR REPLACE FUNCTION public.complete_yookassa_checkout(
  p_user_id uuid,p_idempotency_key uuid,p_product text,p_payment_id text,
  p_confirmation_url text,p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_intent private.yookassa_checkout_intents%ROWTYPE;
  v_expected numeric;
  v_payment public.payments%ROWTYPE;
BEGIN
  IF coalesce(auth.jwt()->>'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'service role required';
  END IF;
  IF p_user_id IS NULL OR p_idempotency_key IS NULL
     OR p_payment_id IS NULL OR p_payment_id = ''
     OR p_confirmation_url IS NULL OR p_confirmation_url NOT LIKE 'https://%'
     OR p_product IS NULL THEN
    RAISE EXCEPTION 'invalid checkout completion';
  END IF;

  v_expected := CASE p_product
    WHEN 'plus_month' THEN 199.00 WHEN 'plus_3m' THEN 537.00
    WHEN 'plus_12m' THEN 1910.00 WHEN 'tokens_50' THEN 25.00
    WHEN 'tokens_100' THEN 50.00 WHEN 'tokens_200' THEN 90.00
    WHEN 'tokens_500' THEN 200.00 WHEN 'tokens_1000' THEN 350.00
    ELSE NULL
  END;
  IF v_expected IS NULL OR p_amount IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'checkout amount does not match product';
  END IF;

  SELECT * INTO v_intent
  FROM private.yookassa_checkout_intents
  WHERE user_id=p_user_id AND idempotency_key=p_idempotency_key
  FOR UPDATE;

  IF NOT FOUND OR v_intent.product IS DISTINCT FROM p_product THEN
    RAISE EXCEPTION 'checkout intent not found';
  END IF;
  IF v_intent.payment_id IS NOT NULL AND v_intent.payment_id IS DISTINCT FROM p_payment_id THEN
    RAISE EXCEPTION 'checkout intent already linked to another payment';
  END IF;

  INSERT INTO public.payments(id,user_id,product,amount,status)
  VALUES (p_payment_id,p_user_id,p_product,v_expected,'pending')
  ON CONFLICT (id) DO NOTHING;

  SELECT * INTO v_payment FROM public.payments WHERE id=p_payment_id FOR UPDATE;
  IF NOT FOUND OR v_payment.user_id IS DISTINCT FROM p_user_id
     OR v_payment.product IS DISTINCT FROM p_product
     OR v_payment.amount IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'payment row does not match checkout intent';
  END IF;

  UPDATE private.yookassa_checkout_intents
  SET payment_id=p_payment_id,confirmation_url=p_confirmation_url
  WHERE user_id=p_user_id AND idempotency_key=p_idempotency_key;
END
$function$;

REVOKE ALL ON FUNCTION public.reserve_yookassa_checkout(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_yookassa_checkout(uuid,uuid,text,text,text,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_yookassa_checkout(uuid,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_yookassa_checkout(uuid,uuid,text,text,text,numeric) TO service_role;
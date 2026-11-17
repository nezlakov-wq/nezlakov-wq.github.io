-- Ensure verified refunds are recorded even if payment creation did not persist.
CREATE OR REPLACE FUNCTION public.settle_yookassa_payment(
  p_payment_id text, p_user_id uuid, p_product text, p_amount numeric, p_event text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_expected numeric;
  v_plus_days integer := 0;
  v_tokens numeric := 0;
  v_shortfall numeric := 0;
BEGIN
  IF coalesce(auth.jwt()->>'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'service role required';
  END IF;
  IF p_payment_id IS NULL OR p_payment_id = ''
     OR p_user_id IS NULL OR p_product IS NULL
     OR p_event IS NULL OR p_event NOT IN ('succeeded', 'refunded') THEN
    RAISE EXCEPTION 'invalid payment settlement arguments';
  END IF;
  CASE p_product
    WHEN 'plus_month' THEN v_expected := 199.00; v_plus_days := 30; v_tokens := 50;
    WHEN 'plus_3m' THEN v_expected := 537.00; v_plus_days := 90; v_tokens := 50;
    WHEN 'plus_12m' THEN v_expected := 1910.00; v_plus_days := 365; v_tokens := 50;
    WHEN 'tokens_50' THEN v_expected := 25.00; v_tokens := 50;
    WHEN 'tokens_100' THEN v_expected := 50.00; v_tokens := 100;
    WHEN 'tokens_200' THEN v_expected := 90.00; v_tokens := 200;
    WHEN 'tokens_500' THEN v_expected := 200.00; v_tokens := 500;
    WHEN 'tokens_1000' THEN v_expected := 350.00; v_tokens := 1000;
    ELSE RAISE EXCEPTION 'unknown product';
  END CASE;
  IF p_amount IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'payment amount does not match product';
  END IF;
  INSERT INTO public.payments (id, user_id, product, amount, status)
  VALUES (p_payment_id, p_user_id, p_product, v_expected, 'pending')
  ON CONFLICT (id) DO NOTHING;
  SELECT * INTO v_payment FROM public.payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 0; END IF;
  IF v_payment.user_id IS DISTINCT FROM p_user_id
     OR v_payment.product IS DISTINCT FROM p_product
     OR v_payment.amount IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'payment record does not match verified provider data';
  END IF;
  IF p_event = 'succeeded' THEN
    IF v_payment.status <> 'pending' THEN RETURN 0; END IF;
    UPDATE public.payments SET status = 'succeeded', paid_at = coalesce(paid_at, now())
    WHERE id = p_payment_id;
    IF v_plus_days > 0 THEN
      PERFORM public.grant_plus(p_user_id, v_plus_days);
    ELSE
      PERFORM public.grant_tokens(p_user_id, v_tokens);
    END IF;
    RETURN 1;
  END IF;
  IF v_payment.status = 'refunded' THEN RETURN 0; END IF;
  IF v_payment.status NOT IN ('pending', 'succeeded') THEN RETURN 0; END IF;
  UPDATE public.payments SET status = 'refunded' WHERE id = p_payment_id;
  IF v_payment.status = 'succeeded' THEN
    v_shortfall := public.revoke_purchase(p_user_id, v_plus_days, v_tokens);
  END IF;
  RETURN coalesce(v_shortfall, 0);
END
$function$;
REVOKE ALL ON FUNCTION public.settle_yookassa_payment(text, uuid, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_yookassa_payment(text, uuid, text, numeric, text) TO service_role;

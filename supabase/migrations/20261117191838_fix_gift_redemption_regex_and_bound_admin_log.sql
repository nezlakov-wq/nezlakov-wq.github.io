-- Repair gift redemption parsing and bound the owner audit-log query.
CREATE OR REPLACE FUNCTION public.sell_gift(msg uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  m public.messages%rowtype;
  gid text;
  price numeric;
  payout numeric;
  bal numeric;
  uid uuid := auth.uid();
  rcpt text[];
  parts text[];
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Требуется вход';
  END IF;

  SELECT * INTO m FROM public.messages WHERE id = msg FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Подарок не найден'; END IF;
  IF m.sender_id = uid THEN RAISE EXCEPTION 'Нельзя продать свой подарок'; END IF;
  IF m.created_at < now() - interval '5 days' THEN
    RAISE EXCEPTION 'Срок продажи истёк (5 дней)';
  END IF;

  parts := regexp_match(m.text, '^\[gift:(\w+)\]$');
  IF parts IS NOT NULL THEN
    gid := parts[1];
    IF NOT EXISTS (
      SELECT 1 FROM public.conversation_members
      WHERE conversation_id = m.conversation_id AND user_id = uid
    ) THEN
      RAISE EXCEPTION 'Подарок не для вас';
    END IF;
  ELSE
    parts := regexp_match(m.text, '^\[ggift:(\w+):([0-9a-f,-]*)\]$');
    IF parts IS NULL THEN RAISE EXCEPTION 'Это не подарок'; END IF;
    gid := parts[1];
    rcpt := string_to_array(parts[2], ',');
    IF NOT (uid::text = ANY(rcpt)) THEN RAISE EXCEPTION 'Подарок не для вас'; END IF;
  END IF;

  SELECT g.price INTO price FROM public.gifts g WHERE g.id = gid;
  IF NOT FOUND OR price IS NULL THEN RAISE EXCEPTION 'Подарок больше недоступен'; END IF;
  payout := round(price * 0.5);

  INSERT INTO public.gift_sales (message_id, user_id) VALUES (msg, uid);
  PERFORM set_config('app.balance_reason', 'gift_sell', true);
  UPDATE public.profiles
  SET balance = coalesce(balance, 0) + payout
  WHERE id = uid
  RETURNING balance INTO bal;
  IF NOT FOUND THEN RAISE EXCEPTION 'Профиль не найден'; END IF;
  RETURN bal;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Уже продано';
END
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_log(lim integer DEFAULT 100)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_mfa();
  IF auth.uid() IS NULL OR auth.uid() <> '852d1d07-897e-4fb0-af14-8530b2c4dd8a'::uuid THEN
    RAISE EXCEPTION 'Недоступно';
  END IF;
  RETURN (
    SELECT coalesce(json_agg(x ORDER BY x.created_at DESC), '[]'::json)
    FROM (
      SELECT l.created_at, l.action, l.details, p.username
      FROM public.admin_log l
      LEFT JOIN public.profiles p ON p.id = l.target_user
      ORDER BY l.created_at DESC
      LIMIT greatest(1, least(coalesce(lim, 100), 200))
    ) x
  );
END
$function$;
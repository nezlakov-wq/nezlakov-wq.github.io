-- A gift may only be sold by its intended recipient in the correct conversation type.
CREATE OR REPLACE FUNCTION public.sell_gift(msg uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  m public.messages%ROWTYPE;
  gid text;
  price numeric;
  payout numeric;
  bal numeric;
  uid uuid := auth.uid();
  rcpt text[];
  parts text[];
  is_group_chat boolean;
  is_channel_chat boolean;
  member_count integer;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'Требуется вход'; END IF;
  SELECT * INTO m FROM public.messages WHERE id = msg FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Подарок не найден'; END IF;
  IF m.sender_id = uid THEN RAISE EXCEPTION 'Нельзя продать свой подарок'; END IF;
  IF m.created_at < now() - interval '5 days' THEN
    RAISE EXCEPTION 'Срок продажи истёк (5 дней)';
  END IF;
  SELECT coalesce(c.is_group, false), coalesce(c.is_channel, false)
  INTO is_group_chat, is_channel_chat
  FROM public.conversations c WHERE c.id = m.conversation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Чат не найден'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.conversation_members cm
    WHERE cm.conversation_id = m.conversation_id AND cm.user_id = uid
  ) OR NOT EXISTS (
    SELECT 1 FROM public.conversation_members cm
    WHERE cm.conversation_id = m.conversation_id AND cm.user_id = m.sender_id
  ) THEN
    RAISE EXCEPTION 'Подарок не для вас';
  END IF;
  parts := regexp_match(m.text, '^\\[gift:(\\w+)\\]$');
  IF parts IS NOT NULL THEN
    IF is_group_chat OR is_channel_chat THEN
      RAISE EXCEPTION 'Личный подарок доступен только в личном чате';
    END IF;
    SELECT count(*) INTO member_count
    FROM public.conversation_members WHERE conversation_id = m.conversation_id;
    IF member_count <> 2 THEN
      RAISE EXCEPTION 'Личный подарок доступен только в чате один на один';
    END IF;
    gid := parts[1];
  ELSE
    parts := regexp_match(m.text, '^\\[ggift:(\\w+):([0-9a-f,-]*)\\]$');
    IF parts IS NULL THEN RAISE EXCEPTION 'Это не подарок'; END IF;
    IF NOT is_group_chat OR is_channel_chat THEN
      RAISE EXCEPTION 'Групповой подарок доступен только в группе';
    END IF;
    gid := parts[1];
    rcpt := string_to_array(parts[2], ',');
    IF NOT (uid::text = ANY(rcpt)) THEN RAISE EXCEPTION 'Подарок не для вас'; END IF;
  END IF;
  SELECT g.price INTO price FROM public.gifts g WHERE g.id = gid;
  IF NOT FOUND OR price IS NULL THEN RAISE EXCEPTION 'Подарок больше недоступен'; END IF;
  payout := round(price * 0.5);
  INSERT INTO public.gift_sales (message_id, user_id) VALUES (msg, uid);
  PERFORM set_config('app.balance_reason', 'gift_sell', true);
  UPDATE public.profiles SET balance = coalesce(balance, 0) + payout
  WHERE id = uid RETURNING balance INTO bal;
  IF NOT FOUND THEN RAISE EXCEPTION 'Профиль не найден'; END IF;
  RETURN bal;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Уже продано';
END
$function$;

CREATE OR REPLACE FUNCTION public.send_gift(conv uuid, gift text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  g record;
  recipient uuid;
  bal numeric;
  grp boolean;
  chan boolean;
  member_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Требуется вход'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.conversation_members
    WHERE conversation_id = conv AND user_id = auth.uid()
  ) THEN RAISE EXCEPTION 'Not a member'; END IF;
  SELECT is_group, is_channel INTO grp, chan FROM public.conversations WHERE id = conv;
  IF NOT FOUND THEN RAISE EXCEPTION 'Чат не найден'; END IF;
  IF coalesce(grp, false) OR coalesce(chan, false) THEN
    RAISE EXCEPTION 'Для групп и каналов отправка подарков недоступна';
  END IF;
  SELECT * INTO g FROM public.gifts WHERE id = gift;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown gift'; END IF;
  SELECT user_id INTO recipient FROM public.conversation_members
  WHERE conversation_id = conv AND user_id <> auth.uid() LIMIT 1;
  SELECT count(*) INTO member_count FROM public.conversation_members WHERE conversation_id = conv;
  IF recipient IS NULL THEN
    IF member_count <> 1 THEN RAISE EXCEPTION 'Неверный личный чат'; END IF;
    INSERT INTO public.messages (conversation_id, sender_id, text)
    VALUES (conv, auth.uid(), '[gift:' || gift || ']');
    RETURN;
  END IF;
  IF member_count <> 2 THEN RAISE EXCEPTION 'Подарки доступны только в чате один на один'; END IF;
  SELECT balance INTO bal FROM public.profiles WHERE id = auth.uid() FOR UPDATE;
  IF coalesce(bal, 0) < g.price THEN RAISE EXCEPTION 'Not enough tokens'; END IF;
  PERFORM set_config('app.balance_reason', 'gift_send', true);
  UPDATE public.profiles SET balance = balance - g.price WHERE id = auth.uid();
  INSERT INTO public.messages (conversation_id, sender_id, text)
  VALUES (conv, auth.uid(), '[gift:' || gift || ']');
END
$function$;

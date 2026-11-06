-- Подарок в личном чате: отправитель платит, получатель токены автоматически не получает.
-- Получатель может продать подарок сам (sell_gift, 50% в течение 5 дней).
create or replace function public.send_gift(conv uuid, gift text)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare g record; recipient uuid; bal numeric; grp boolean;
begin
  if not exists (select 1 from public.conversation_members where conversation_id = conv and user_id = auth.uid()) then
    raise exception 'Not a member';
  end if;
  select is_group into grp from public.conversations where id = conv;
  if coalesce(grp, false) then raise exception 'Для групп используйте групповой подарок'; end if;
  select * into g from public.gifts where id = gift;
  if not found then raise exception 'Unknown gift'; end if;
  select user_id into recipient from public.conversation_members where conversation_id = conv and user_id <> auth.uid() limit 1;
  if recipient is null or recipient = auth.uid() then
    -- Подарок себе (Избранное): баланс не меняем
    insert into public.messages (conversation_id, sender_id, text) values (conv, auth.uid(), '[gift:' || gift || ']');
    return;
  end if;
  select balance into bal from public.profiles where id = auth.uid() for update;
  if coalesce(bal, 0) < g.price then raise exception 'Not enough tokens'; end if;
  -- Отправитель платит стоимость; получатель токены не получает автоматически
  perform set_config('app.balance_reason', 'gift_send', true);
  update public.profiles set balance = balance - g.price where id = auth.uid();
  insert into public.messages (conversation_id, sender_id, text) values (conv, auth.uid(), '[gift:' || gift || ']');
end $function$;

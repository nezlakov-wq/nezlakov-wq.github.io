-- Возврат платежа: откат выданного за покупку (Plus и токены).
-- Баланс не уходит ниже нуля: недостача возвращается вызывающему коду и пишется в журнал.
-- Вызывается только сервером (service_role) из yookassa-webhook при refund.succeeded.

create or replace function public.revoke_purchase(uid uuid, days integer, tokens numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  cur numeric;
  take numeric;
  shortfall numeric := 0;
begin
  select coalesce(balance, 0) into cur from public.profiles where id = uid for update;
  if not found then return 0; end if;

  take := least(coalesce(tokens, 0), cur);
  shortfall := coalesce(tokens, 0) - take;
  if take > 0 then
    perform set_config('app.balance_reason', 'refund', true);
    update public.profiles set balance = balance - take where id = uid;
  end if;

  if days > 0 then
    update public.profiles
       set plus_until = greatest(plus_until - make_interval(days => days), now())
     where id = uid and plus_until is not null;
  end if;

  return shortfall;
end $$;

revoke all on function public.revoke_purchase(uuid, integer, numeric) from public, anon, authenticated;
grant execute on function public.revoke_purchase(uuid, integer, numeric) to service_role;

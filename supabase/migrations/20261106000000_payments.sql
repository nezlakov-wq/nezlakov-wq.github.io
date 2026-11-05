-- Платежи ЮKassa: журнал покупок и выдача токенов за покупку.
-- Пишет только сервер (service_role). Пользователь видит только свои платежи.

create table if not exists public.payments (
  id           text primary key,                       -- id платежа в ЮKassa
  user_id      uuid not null references public.profiles(id) on delete cascade,
  product      text not null,                          -- код товара, см. PRODUCTS в edge-функциях
  amount       numeric(10,2) not null,
  status       text not null default 'pending',        -- pending | succeeded | canceled
  created_at   timestamptz not null default now(),
  paid_at      timestamptz
);

alter table public.payments enable row level security;

drop policy if exists payments_select_own on public.payments;
create policy payments_select_own on public.payments
  for select to authenticated using (auth.uid() = user_id);

-- Начисление токенов за покупку (как grant_plus: только service_role)
create or replace function public.grant_tokens(uid uuid, amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.balance_reason', 'purchase', true);
  update public.profiles
     set balance = coalesce(balance, 0) + amount
   where id = uid;
end $$;

revoke all on function public.grant_tokens(uuid, numeric) from public, anon, authenticated;
grant execute on function public.grant_tokens(uuid, numeric) to service_role;

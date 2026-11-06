-- Серверы для звонков (STUN/TURN). Таблица закрыта для прямого чтения клиентами:
-- отдаёт её только функция get_ice_servers, и только для вошедших пользователей.
create table if not exists public.turn_config (
  id         int primary key default 1 check (id = 1),
  stun_url   text not null,
  turn_urls  text[] not null,
  username   text not null,
  credential text not null
);

alter table public.turn_config enable row level security;  -- политик нет: прямого доступа нет

create or replace function public.get_ice_servers()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare r public.turn_config;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into r from public.turn_config where id = 1;
  if r is null then return json_build_object('iceServers', json_build_array()); end if;
  return json_build_object('iceServers', json_build_array(
    json_build_object('urls', r.stun_url),
    json_build_object('urls', to_json(r.turn_urls), 'username', r.username, 'credential', r.credential)
  ));
end $$;

revoke all on function public.get_ice_servers() from public, anon;
grant execute on function public.get_ice_servers() to authenticated;

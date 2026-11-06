-- Статистика канала: видит только владелец канала.
-- Просмотры постов не считаются (их нет в схеме).

create or replace function public.channel_stats(conv uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare owner uuid; res json;
begin
  select created_by into owner from public.conversations where id = conv and is_channel;
  if owner is null then raise exception 'Канал не найден'; end if;
  if owner <> auth.uid() then raise exception 'Статистику видит только владелец канала'; end if;
  select json_build_object(
    'subscribers', (select count(*) from public.conversation_members where conversation_id = conv),
    'joined_7d', (select count(*) from public.conversation_members where conversation_id = conv and joined_at > now() - interval '7 days'),
    'joined_30d', (select count(*) from public.conversation_members where conversation_id = conv and joined_at > now() - interval '30 days'),
    'posts_7d', (select count(*) from public.messages where conversation_id = conv and created_at > now() - interval '7 days'),
    'posts_30d', (select count(*) from public.messages where conversation_id = conv and created_at > now() - interval '30 days'),
    'posts_total', (select count(*) from public.messages where conversation_id = conv)
  ) into res;
  return res;
end $$;

revoke all on function public.channel_stats(uuid) from public, anon;
grant execute on function public.channel_stats(uuid) to authenticated;

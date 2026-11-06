-- Описание канала и редактирование названия/описания владельцем.
alter table public.conversations add column if not exists description text;

create or replace function public.update_channel(conv uuid, new_name text, new_description text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.conversations c where c.id = conv and c.is_channel and c.created_by = auth.uid()) then
    raise exception 'not allowed';
  end if;
  update public.conversations
     set name = left(trim(new_name), 60),
         description = left(trim(coalesce(new_description, '')), 300)
   where id = conv;
end $$;

revoke all on function public.update_channel(uuid, text, text) from public, anon;
grant execute on function public.update_channel(uuid, text, text) to authenticated;

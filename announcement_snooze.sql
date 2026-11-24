create schema if not exists announcement_private;
revoke all on schema announcement_private from public,anon;
grant usage on schema announcement_private to authenticated;
create table announcement_private.snoozes(user_id uuid not null references auth.users(id) on delete cascade,announcement_id bigint not null references public.announcements(id) on delete cascade,next_reminder timestamptz not null,primary key(user_id,announcement_id));
alter table announcement_private.snoozes enable row level security;
revoke all on announcement_private.snoozes from public,anon,authenticated;
create function announcement_private.snooze(p_action text,p_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.is_staff() or auth.uid() is null then raise sqlstate 'PT403' using message='Требуется вход сотрудника';end if;
 if p_action='later' then
  if not exists(select 1 from public.announcements where id=p_id and is_active) then raise exception 'Объявление больше не активно';end if;
  insert into announcement_private.snoozes values(auth.uid(),p_id,now()+interval '4 hours') on conflict(user_id,announcement_id) do update set next_reminder=excluded.next_reminder;
 elsif p_action='clear' then delete from announcement_private.snoozes where user_id=auth.uid() and announcement_id=p_id;
 elsif p_action='claim' then
  with due as(update announcement_private.snoozes s set next_reminder=now()+interval '4 hours' where user_id=auth.uid() and next_reminder<=now() and exists(select 1 from public.announcements a where a.id=s.announcement_id and a.is_active) returning announcement_id)
  select coalesce(jsonb_agg(announcement_id),'[]'::jsonb) into result from due;
  return jsonb_build_object('due',result);
 elsif p_action<>'get' then raise exception 'Неизвестное действие';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',s.announcement_id,'next_reminder',s.next_reminder)),'[]'::jsonb) into result from announcement_private.snoozes s join public.announcements a on a.id=s.announcement_id and a.is_active where s.user_id=auth.uid();
 return jsonb_build_object('snoozes',result);
end $$;
create function public.announcement_snooze(p_action text,p_id bigint default null) returns jsonb language sql security invoker set search_path='' as $$select announcement_private.snooze(p_action,p_id)$$;
revoke all on function announcement_private.snooze(text,bigint),public.announcement_snooze(text,bigint) from public,anon;
grant execute on function announcement_private.snooze(text,bigint),public.announcement_snooze(text,bigint) to authenticated;
notify pgrst,'reload schema';

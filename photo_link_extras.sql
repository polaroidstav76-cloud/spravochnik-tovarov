-- Shared staff viewing state, optional size advice and branch-specific public contacts.
alter table photo_private.orders add column if not exists needs_size_advice boolean not null default false;
create table photo_private.order_views(order_id uuid primary key references photo_private.orders(id) on delete cascade,seen_updated_at timestamptz not null,viewed_at timestamptz not null default now(),viewed_by uuid references public.staff_accounts(user_id));
create table photo_private.contacts(branch_id bigint primary key references public.sales_branches(id),links jsonb not null default '{}'::jsonb);
alter table photo_private.order_views enable row level security;
alter table photo_private.contacts enable row level security;
revoke all on photo_private.order_views,photo_private.contacts from public,anon,authenticated;
-- Verified public branch contacts from foto-26.ru/contacts, 22 November 2026.
insert into photo_private.contacts(branch_id,links)
select id,jsonb_build_object('whatsapp','https://wa.me/'||phone,'telegram','https://t.me/+'||phone) from (
 select b.id,case when b.name like '%26/4%' then '79097705897' when b.name like '%26/10%' then '79054150351' when b.name like '%84/6%' then '79614681327' when b.name like '%75%' and b.name ilike '%параллель%' then '79614562030' end phone from public.sales_branches b where b.is_active and not b.is_test and not b.is_workshop
)x where phone is not null on conflict do nothing;
do $$begin execute replace(pg_get_functiondef('photo_private.api(text,jsonb,uuid)'::regprocedure),'FUNCTION photo_private.api(','FUNCTION photo_private.api_before_link_extras(');end $$;
revoke all on function photo_private.api_before_link_extras(text,jsonb,uuid) from public,anon,authenticated;
create or replace function photo_private.api(p_action text,p_data jsonb,p_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.staff_accounts%rowtype;o photo_private.orders%rowtype;m jsonb;r jsonb;k text;url text;seen timestamptz;links jsonb;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 if p_actor is not null then select * into a from public.staff_accounts where user_id=p_actor and active;if not found then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;end if;
 if p_action='contacts_save' then
  if a.role is distinct from 'admin' then raise sqlstate 'PT403' using message='Контакты меняет администратор';end if;
  links:=p_data->'links';if jsonb_typeof(links) is distinct from 'object' then raise exception 'Укажите контакты филиала';end if;
  for k,url in select key,value from jsonb_each_text(links) loop
   if k not in('whatsapp','telegram','max') then raise exception 'Неизвестный мессенджер';end if;
   if url<>'' and (length(url)>2048 or url !~ '^https://' or (k='whatsapp' and url !~ '^https://(wa[.]me|api[.]whatsapp[.]com)/') or (k='telegram' and url !~ '^https://t[.]me/') or (k='max' and url !~ '^https://max[.]ru/')) then raise exception 'Укажите полную ссылку нужного мессенджера';end if;
  end loop;
  insert into photo_private.contacts(branch_id,links) values((p_data->>'branch_id')::bigint,links) on conflict(branch_id) do update set links=excluded.links;return '{"ok":true}';
 elsif p_action='seen' then
  if p_actor is null then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
  select * into o from photo_private.orders where id=(p_data->>'id')::uuid;
  if not found or not coalesce((a.role='admin' or o.created_by=p_actor or o.branch_id=(select branch_id from public.sales_shifts where id=(p_data->>'shift_id')::bigint and ended_at is null)),false) then raise sqlstate 'PT403' using message='Нет доступа к этой ссылке';end if;
  seen:=least(o.updated_at,(p_data->>'updated_at')::timestamptz);if seen is null then raise exception 'Обновите список ссылок';end if;
  insert into photo_private.order_views(order_id,seen_updated_at,viewed_by) values(o.id,seen,p_actor) on conflict(order_id) do update set seen_updated_at=greatest(photo_private.order_views.seen_updated_at,excluded.seen_updated_at),viewed_at=now(),viewed_by=p_actor;return '{"ok":true}';
 elsif p_action='consultation' then
  select * into o from photo_private.orders where token=p_data->>'token';if not found then raise sqlstate 'PT404' using message='Ссылка не найдена';end if;
  if jsonb_typeof(p_data->'needed') is distinct from 'boolean' then raise exception 'Укажите, нужна ли консультация';end if;
  update photo_private.orders set needs_size_advice=(p_data->>'needed')::boolean,updated_at=now() where id=o.id;return '{"ok":true}';
 end if;
 m:=photo_private.api_before_link_extras(p_action,p_data,p_actor);
 if p_action='branches' then
  select coalesce(jsonb_agg(b||jsonb_build_object('contacts',coalesce(c.links,'{}'::jsonb))),'[]'::jsonb) into r from jsonb_array_elements(m->'branches')b left join photo_private.contacts c on c.branch_id=(b->>'id')::bigint;
  return m||jsonb_build_object('branches',r);
 elsif p_action='list' then
  select coalesce(jsonb_agg(item||jsonb_build_object('needs_size_advice',o2.needs_size_advice,'is_new',v.seen_updated_at is null or o2.updated_at>v.seen_updated_at,'viewed_at',v.viewed_at)),'[]'::jsonb) into r from jsonb_array_elements(m->'orders')item join photo_private.orders o2 on o2.id=(item->>'id')::uuid left join photo_private.order_views v on v.order_id=o2.id;
  return m||jsonb_build_object('orders',r);
 elsif p_action='manifest' then
  select * into o from photo_private.orders where token=p_data->>'token';select c.links into links from photo_private.contacts c where c.branch_id=o.branch_id;
  return m||jsonb_build_object('needs_size_advice',o.needs_size_advice,'contacts',coalesce(links,'{}'::jsonb));
 elsif p_action='create' and coalesce(p_data->>'needs_size_advice','false')='true' then
  update photo_private.orders set needs_size_advice=true where token=m->>'token';
 end if;
 return m;
end $$;
revoke all on function photo_private.api(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function photo_private.api(text,jsonb,uuid) to service_role;
notify pgrst,'reload schema';

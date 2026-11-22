-- Staff can revoke an individual order link without deleting original files on Disk.
alter table photo_private.orders add column deleted_at timestamptz;
alter table photo_private.orders add column deleted_by uuid references public.staff_accounts(user_id);
do $$declare def text;begin
 def:=pg_get_functiondef('photo_private.api_before_crop(text,jsonb,uuid)'::regprocedure);
 if position('where (a.role=' in def)=0 then raise exception 'Unexpected photo list implementation';end if;
 execute replace(def,'where (a.role=','where ord.deleted_at is null and (a.role=');
end $$;
do $$begin execute replace(pg_get_functiondef('photo_private.api(text,jsonb,uuid)'::regprocedure),'FUNCTION photo_private.api(','FUNCTION photo_private.api_before_link_management(');end $$;
revoke all on function photo_private.api_before_link_management(text,jsonb,uuid) from public,anon,authenticated;
create or replace function photo_private.api(p_action text,p_data jsonb,p_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.staff_accounts%rowtype;o photo_private.orders%rowtype;m jsonb;r jsonb;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 -- Lock token operations against concurrent revocation; previously issued temporary download URLs may expire later.
 if p_action not in ('configure','secret') and p_data ? 'token' then
  select * into o from photo_private.orders where token=p_data->>'token' for update;
  if found and o.deleted_at is not null then raise sqlstate 'PT404' using message='Эта ссылка удалена сотрудником фотоцентра';end if;
  if p_action='consultation' and o.source is distinct from 'offline' then raise sqlstate 'PT403' using message='Консультация по размеру доступна только для оффлайн-заказа';end if;
 end if;
 if p_action='delete_link' then
  select * into a from public.staff_accounts where user_id=p_actor and active;
  if not found then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
  select * into o from photo_private.orders where id=(p_data->>'id')::uuid for update;
  if not found or not coalesce((a.role='admin' or o.created_by=p_actor or o.branch_id=(select branch_id from public.sales_shifts where id=(p_data->>'shift_id')::bigint and ended_at is null and (employee_id=a.person_id or exists(select 1 from public.sales_shift_employees se where se.shift_id=public.sales_shifts.id and se.employee_id=a.person_id)))),false) then raise sqlstate 'PT403' using message='Нет доступа к этой ссылке';end if;
  update photo_private.orders set deleted_at=coalesce(deleted_at,now()),deleted_by=coalesce(deleted_by,p_actor) where id=o.id;
  return '{"ok":true}';
 end if;
 m:=photo_private.api_before_link_management(p_action,p_data,p_actor);
 if p_action='list' then
  select coalesce(jsonb_agg(item order by n),'[]'::jsonb) into r from jsonb_array_elements(m->'orders') with ordinality items(item,n) join photo_private.orders ord on ord.id=(item->>'id')::uuid where ord.deleted_at is null;
  return m||jsonb_build_object('orders',r);
 elsif p_action='manifest' and o.source='staff' then return m||jsonb_build_object('needs_size_advice',false);
 end if;
 return m;
end $$;
revoke all on function photo_private.api(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function photo_private.api(text,jsonb,uuid) to service_role;
notify pgrst,'reload schema';

-- Remove a shared purchase request without deleting material stock or completed purchase snapshots.
create schema if not exists purchase_private;
revoke all on schema purchase_private from public,anon;
grant usage on schema purchase_private to authenticated;
create table purchase_private.deleted_requests(
 request_id bigint primary key,deleted_at timestamptz not null default now(),
 deleted_by uuid not null,request_snapshot jsonb not null
);
alter table purchase_private.deleted_requests enable row level security;
create policy private_audit on purchase_private.deleted_requests for all to authenticated using(false) with check(false);
revoke all on purchase_private.deleted_requests from public,anon,authenticated;
create function purchase_private.delete_request(p_id bigint,p_expected_status text,p_expected_ordered_qty numeric)
returns boolean language plpgsql security definer set search_path='' as $$
declare target public.stock_requests;
begin
 if auth.uid() is null or not public.is_staff() then raise sqlstate 'PT403' using message='Требуется активный доступ сотрудника';end if;
 select * into target from public.stock_requests where id=p_id for update;
 if not found then return false;end if;
 if target.status is distinct from p_expected_status or target.ordered_qty is distinct from p_expected_ordered_qty then
  raise sqlstate 'PT409' using message='Заявка изменилась: по ней уже изменили закупленное количество или статус. Обновите список и проверьте позицию перед удалением';
 end if;
 insert into purchase_private.deleted_requests(request_id,deleted_by,request_snapshot) values(target.id,auth.uid(),to_jsonb(target));
 delete from public.stock_requests where id=target.id;
 return true;
end $$;
create function public.stock_request_delete(p_id bigint,p_expected_status text,p_expected_ordered_qty numeric)
returns boolean language sql security invoker set search_path='' as $$select purchase_private.delete_request(p_id,p_expected_status,p_expected_ordered_qty)$$;
revoke all on function purchase_private.delete_request(bigint,text,numeric),public.stock_request_delete(bigint,text,numeric) from public,anon,authenticated;
grant execute on function purchase_private.delete_request(bigint,text,numeric),public.stock_request_delete(bigint,text,numeric) to authenticated;

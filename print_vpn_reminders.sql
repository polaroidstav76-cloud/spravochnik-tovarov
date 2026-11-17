create table print_private.vpn_slots(source_device uuid not null references print_private.devices(id),direction text not null check(direction in ('wideformat','dtf')),due_at timestamptz not null,created_at timestamptz not null default now(),primary key(source_device,direction,due_at));
alter table print_private.vpn_slots enable row level security;
create policy deny_direct on print_private.vpn_slots for all to authenticated using(false) with check(false);
revoke all on print_private.vpn_slots from public,anon,authenticated;
create function print_private.vpn_publish(p_token text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d print_private.devices;x jsonb;due timestamptz;kind text;
begin
 if coalesce(p_token,'')!~'^[a-f0-9]{64}$' then raise sqlstate 'PT401' using message='Нет доступа компьютера';end if;
 select * into d from print_private.devices where active and role='source' and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found then raise sqlstate 'PT401' using message='Нет доступа компьютера';end if;
 if coalesce(jsonb_typeof(p_payload->'slots'),'')<>'array' or jsonb_array_length(p_payload->'slots')>16 then raise exception 'Недопустимое расписание';end if;
 for x in select value from jsonb_array_elements(p_payload->'slots') loop
  due:=(x->>'due_at')::timestamptz;kind:=x->>'direction';
  if due is null or due<now()-interval '20 minutes' or due>now()+interval '8 days' or kind not in ('wideformat','dtf') then raise exception 'Недопустимое расписание';end if;
 end loop;
 delete from print_private.vpn_slots s where s.source_device=d.id and not exists(select 1 from jsonb_array_elements(p_payload->'slots') v where v->>'direction'=s.direction and (v->>'due_at')::timestamptz=s.due_at);
 insert into print_private.vpn_slots(source_device,direction,due_at) select d.id,value->>'direction',(value->>'due_at')::timestamptz from jsonb_array_elements(p_payload->'slots') on conflict do nothing;
 update print_private.devices set last_seen=now() where id=d.id;
 delete from print_private.vpn_slots where due_at<now()-interval '1 day';
 return jsonb_build_object('saved',true);
end $$;
create function public.print_vpn_publish(p_token text,p_payload jsonb) returns jsonb language sql security invoker set search_path='' as $$select print_private.vpn_publish(p_token,p_payload)$$;
create function print_private.vpn_list(p_shift_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_staff() then raise sqlstate 'PT403' using message='Требуется вход';end if;
 if not exists(select 1 from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id where s.id=p_shift_id and s.status='open' and b.name='Тухачевского 26/10') then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',v.source_device::text||':'||v.direction||':'||v.due_at::text,'direction',v.direction,'due_at',v.due_at,'until',v.due_at+interval '15 minutes') order by v.due_at) from print_private.vpn_slots v join print_private.devices d on d.id=v.source_device and d.active where now()>=v.due_at-interval '15 minutes' and now()<v.due_at+interval '15 minutes'),'[]'::jsonb);
end $$;
create function public.print_vpn_reminders(p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$select print_private.vpn_list(p_shift_id)$$;
revoke all on function print_private.vpn_publish(text,jsonb),print_private.vpn_list(bigint),public.print_vpn_publish(text,jsonb),public.print_vpn_reminders(bigint) from public,anon,authenticated;
grant execute on function print_private.vpn_publish(text,jsonb),public.print_vpn_publish(text,jsonb) to service_role;
grant execute on function print_private.vpn_list(bigint),public.print_vpn_reminders(bigint) to authenticated;

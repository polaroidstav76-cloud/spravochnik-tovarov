-- Preserve Windows shutdown and resume events without creating any new Telegram notification type.
create table attendance_private.power_events(
 device_id uuid not null references attendance_private.devices(id),kind text not null check(kind in ('boot','resume','shutdown','suspend','unexpected_restart')),
 event_at timestamptz not null,source text not null,record_id text not null,
 received_at timestamptz not null default now(),primary key(device_id,kind,event_at,source)
);
create index attendance_power_event_time on attendance_private.power_events(event_at,device_id);
alter table attendance_private.power_events enable row level security;
create policy private_only on attendance_private.power_events for all to authenticated using(false) with check(false);
revoke all on attendance_private.power_events from public,anon,authenticated;

alter function attendance_private.device_api(text,text,jsonb) rename to device_api_v1;
create function attendance_private.device_api(p_action text,p_token text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare dev attendance_private.devices;cfg attendance_private.branches;event jsonb;kind text;stamp timestamptz;src text;d date;start_at timestamptz;counted int:=0;local_now timestamp:=now() at time zone 'Europe/Moscow';
begin
 if p_action<>'events' then return attendance_private.device_api_v1(p_action,p_token,p_payload);end if;
 if coalesce(p_token,'')!~'^[a-f0-9]{64}$' then raise sqlstate 'PT401' using message='Нет доступа компьютера';end if;
 select * into dev from attendance_private.devices where active and token_hash=encode(extensions.digest(p_token,'sha256'),'hex') for update;
 if not found then raise sqlstate 'PT401' using message='Компьютер отключён';end if;
 if coalesce(jsonb_typeof(p_payload->'events'),'')<>'array' or jsonb_array_length(p_payload->'events')>64 then raise exception 'Недопустимый список событий';end if;
 select * into cfg from attendance_private.branches where branch_id=dev.branch_id;
 for event in select value from jsonb_array_elements(p_payload->'events') order by value->>'at' loop
  kind:=event->>'kind';stamp:=(event->>'at')::timestamptz;src:=event->>'source';
  if kind is null or kind not in ('boot','resume','shutdown','suspend','unexpected_restart') or stamp is null or stamp>now()+interval '2 minutes' or stamp<now()-interval '31 days' or coalesce(length(src),0) not between 1 and 100 or coalesce(length(event->>'record_id'),0) not between 1 and 40 then raise exception 'Некорректное событие Windows';end if;
  insert into attendance_private.power_events(device_id,kind,event_at,source,record_id) values(dev.id,kind,stamp,src,event->>'record_id') on conflict do nothing;
  d:=(stamp at time zone 'Europe/Moscow')::date;
  if kind in ('boot','resume') then
   perform attendance_private.ensure_day(dev.branch_id,d);
   insert into attendance_private.boots(device_id,boot_at) values(dev.id,stamp) on conflict do nothing;
   if (stamp at time zone 'Europe/Moscow')::time<cfg.closing then
    update attendance_private.days set boot_at=least(boot_at,stamp),continuous=false where branch_id=dev.branch_id and day=d;
   end if;
   counted:=counted+1;
  end if;
 end loop;
 select max(event_at) into start_at from attendance_private.power_events pe where pe.device_id=dev.id and pe.kind in ('boot','resume');
 update attendance_private.devices set last_seen=now(),last_boot=greatest(last_boot,start_at),version=left(p_payload->>'version',20) where id=dev.id;
 -- Reuse the existing single boot notification. Shutdown events are never enqueued.
 if cfg.enabled and local_now::date>=cfg.monitor_from and local_now::time<cfg.closing and exists(select 1 from attendance_private.days where branch_id=dev.branch_id and day=local_now::date and boot_at is not null and not excluded) then
  perform attendance_private.enqueue(dev.branch_id,local_now::date,'boot');
 end if;
 return jsonb_build_object('saved',true,'accepted',jsonb_array_length(p_payload->'events'),'server_time',now());
end $$;

alter function attendance_private.admin(text,jsonb) rename to admin_v1;
create function attendance_private.admin(p_action text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор';end if;
 result:=attendance_private.admin_v1(p_action,p_payload);
 if p_action='report' then
  result:=jsonb_set(result,'{days}',(select coalesce(jsonb_agg(r||jsonb_build_object(
   'shutdown_at',(select max(e.event_at) from attendance_private.power_events e join attendance_private.devices v on v.id=e.device_id where v.branch_id=(r->>'branch_id')::bigint and (e.event_at at time zone 'Europe/Moscow')::date=(r->>'day')::date and e.kind in ('shutdown','suspend')),
   'power_events',(select coalesce(jsonb_agg(jsonb_build_object('kind',e.kind,'at',e.event_at,'source',e.source) order by e.event_at),'[]'::jsonb) from attendance_private.power_events e join attendance_private.devices v on v.id=e.device_id where v.branch_id=(r->>'branch_id')::bigint and (e.event_at at time zone 'Europe/Moscow')::date=(r->>'day')::date)
  ) order by r->>'day' desc,r->>'branch'),'[]'::jsonb) from jsonb_array_elements(result->'days') r));
 end if;
 return result;
end $$;
revoke all on function attendance_private.device_api_v1(text,text,jsonb),attendance_private.admin_v1(text,jsonb),attendance_private.device_api(text,text,jsonb),attendance_private.admin(text,jsonb) from public,anon,authenticated;
grant execute on function attendance_private.device_api(text,text,jsonb) to service_role;
grant execute on function attendance_private.admin(text,jsonb) to authenticated;
-- Existing public invoker wrappers resolve the new checked entry points by name.

create or replace function public.attendance_device_api(p_action text,p_token text,p_payload jsonb) returns jsonb language sql security invoker set search_path='' as $$select attendance_private.device_api(p_action,p_token,p_payload)$$;
create or replace function public.attendance_admin(p_action text,p_payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select attendance_private.admin(p_action,p_payload)$$;

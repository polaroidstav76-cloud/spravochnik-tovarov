do $$
declare admin_id uuid;bid bigint;pid bigint;col bigint;device uuid;token text:=repeat('d',64);d date:=(now() at time zone 'Europe/Moscow')::date-2;event_data jsonb;result jsonb;item jsonb;blocked boolean;
begin
 select user_id into admin_id from public.staff_accounts where active and role='admin' limit 1;
 insert into public.sales_branches(name,is_test) values('__power_events_'||gen_random_uuid(),true) returning id into bid;
 insert into public.sales_people(name) values('__power_events') returning id into pid;
 insert into public.schedule_columns(title,branch_id,slots) values('__power_events',bid,1) returning id into col;
 insert into public.schedule_months(month,published) values(date_trunc('month',d)::date,true) on conflict(month) do update set published=true;
 insert into public.schedule_cells(work_date,column_id,slot,person_id) values(d,col,1,pid),(d+1,col,1,pid);
 insert into attendance_private.branches(branch_id,enabled,monitor_from) values(bid,false,d);
 insert into attendance_private.devices(branch_id,label,token_hash) values(bid,'test pc',encode(extensions.digest(token,'sha256'),'hex')) returning id into device;
 perform attendance_private.ensure_day(bid,d+1);
 update attendance_private.days set continuous=true where branch_id=bid and day=d+1;
 event_data:=jsonb_build_array(
 jsonb_build_object('kind','boot','at',(d+time '09:50') at time zone 'Europe/Moscow','source','Microsoft-Windows-Kernel-General:12','record_id','100'),
 jsonb_build_object('kind','shutdown','at',(d+time '20:05') at time zone 'Europe/Moscow','source','Microsoft-Windows-Kernel-General:13','record_id','101'),
 jsonb_build_object('kind','resume','at',(d+1+time '09:45') at time zone 'Europe/Moscow','source','Microsoft-Windows-Kernel-Power:107','record_id','102'));
 execute 'set local role service_role';
 perform public.attendance_device_api('events',token,jsonb_build_object('events',event_data,'version','1.1.0'));
 perform public.attendance_device_api('events',token,jsonb_build_object('events',event_data,'version','1.1.0'));
 execute 'reset role';
 if (select count(*) from attendance_private.power_events where device_id= device)<>3 then raise exception 'Duplicate events stored';end if;
 if not exists(select 1 from attendance_private.days where branch_id=bid and day=d+1 and boot_at=(d+1+time '09:45') at time zone 'Europe/Moscow' and not continuous) then raise exception 'Next-day resumed arrival not repaired';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 result:=public.attendance_admin('report',jsonb_build_object('from',d,'to',d+1));
 execute 'reset role';
 select value into item from jsonb_array_elements(result->'days') where (value->>'branch_id')::bigint=bid and (value->>'day')::date=d;
 if (item->>'shutdown_at')::timestamptz is distinct from ((d+time '20:05') at time zone 'Europe/Moscow') then raise exception 'Shutdown missing from history';end if;
 if exists(select 1 from attendance_private.outbox where branch_id=bid) then raise exception 'Shutdown/history backfill created notification';end if;
 execute 'set local role service_role';
 blocked:=false;begin perform public.attendance_device_api('events',repeat('a',64),jsonb_build_object('events',event_data));exception when sqlstate 'PT401' then blocked:=true;end;
 execute 'reset role';if not blocked then raise exception 'Wrong device accepted';end if;
 if has_table_privilege('authenticated','attendance_private.power_events','select') or has_function_privilege('authenticated','attendance_private.admin_v1(text,jsonb)','execute') then raise exception 'Internal access exposed';end if;
end $$;

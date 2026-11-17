-- Full transaction rollback required. No test notifications are committed.
do $test$
declare actor uuid;staff uuid;b bigint;person bigint;helper bigint;col bigint;code text;token text;dev uuid;r jsonb;d date:=(now() at time zone 'Europe/Moscow')::date-1;boot timestamptz;blocked boolean;
begin
 select user_id into actor from public.staff_accounts where active and role='admin' limit 1;
 select user_id into staff from public.staff_accounts where active and role='staff' limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 insert into public.sales_branches(name,is_active,is_test,is_workshop) values('__attendance_'||gen_random_uuid(),true,false,false) returning id into b;
 insert into public.sales_people(name) values('__attendance_primary') returning id into person;
 insert into public.sales_people(name) values('__attendance_helper') returning id into helper;
 insert into public.schedule_columns(title,branch_id,slots) values('__attendance',b,2) returning id into col;
 insert into public.schedule_months(month,published) values(date_trunc('month',d)::date,true) on conflict(month) do update set published=true;
 insert into public.schedule_cells(work_date,column_id,slot,person_id) values(d,col,1,person),(d,col,2,helper);
 execute 'set local role authenticated';
 perform public.attendance_admin('save',jsonb_build_object('branch_id',b,'enabled',true,'opening','10:00','closing','20:00','monitor_from',d));
 r:=public.attendance_admin('pair',jsonb_build_object('branch_id',b));code:=r->>'code';
 execute 'reset role';
 if length(code)<>32 then raise exception 'Pair code missing';end if;
 execute 'set local role service_role';
 r:=public.attendance_device_api('pair','',jsonb_build_object('code',code,'label','Test PC'));token:=r->>'token';dev:=(r->>'device_id')::uuid;
 blocked:=false;begin perform public.attendance_device_api('pair','',jsonb_build_object('code',code));exception when sqlstate 'PT401' then blocked:=true;end;
 if not blocked then raise exception 'Pair code reused';end if;
 boot:=(d+time '10:15') at time zone 'Europe/Moscow';
 perform public.attendance_device_api('report',token,jsonb_build_object('boot_at',boot,'version','test'));
 perform public.attendance_device_api('report',token,jsonb_build_object('boot_at',boot,'version','test'));
 perform public.attendance_device_api('report',token,jsonb_build_object('boot_at',(d+time '11:00') at time zone 'Europe/Moscow'));
 execute 'reset role';
 if (select count(*) from attendance_private.boots where device_id=dev)<>2 then raise exception 'Duplicate boot stored';end if;
 if not exists(select 1 from attendance_private.days where branch_id=b and day=d and person_id=person and boot_at=boot) then raise exception 'Primary schedule or first boot incorrect';end if;
 if exists(select 1 from attendance_private.devices where id=dev and token_hash=token) then raise exception 'Plaintext token stored';end if;
 execute 'set local role authenticated';
 r:=public.attendance_admin('report',jsonb_build_object('from',d,'to',d));
 execute 'reset role';
 if not exists(select 1 from jsonb_array_elements(r->'days') x where (x->>'branch_id')::bigint=b and (x->>'minutes_late')::int=15 and (x->>'counted')::boolean) then raise exception 'Lateness stats incorrect';end if;
 -- Earlier offline event corrects the first arrival; restarts cannot make it later.
 execute 'set local role service_role';
 perform public.attendance_device_api('report',token,jsonb_build_object('boot_at',(d+time '09:50') at time zone 'Europe/Moscow'));
 execute 'reset role';
 if not exists(select 1 from attendance_private.days where branch_id=b and day=d and boot_at=(d+time '09:50') at time zone 'Europe/Moscow') then raise exception 'Offline first boot lost';end if;
 -- After-closing boot is not an arrival, nor an alert type.
 execute 'set local role service_role';
 perform public.attendance_device_api('report',token,jsonb_build_object('boot_at',(d-1+time '21:00') at time zone 'Europe/Moscow'));
 execute 'reset role';
 if exists(select 1 from attendance_private.days where branch_id=b and day=d-1 and boot_at is not null) then raise exception 'After-hours boot treated as arrival';end if;
 if exists(select 1 from attendance_private.outbox where branch_id=b) then raise exception 'Historical event caused Telegram message';end if;
 execute 'set local role authenticated';
 perform public.attendance_admin('exclude',jsonb_build_object('branch_id',b,'day',d,'excluded',true,'note','Internet outage review'));
 r:=public.attendance_admin('report',jsonb_build_object('from',d,'to',d));
 execute 'reset role';
 if exists(select 1 from jsonb_array_elements(r->'days') x where (x->>'branch_id')::bigint=b and (x->>'counted')::boolean) then raise exception 'Excluded day still counted';end if;
 -- Device revocation immediately stops both new reports and heartbeats.
 execute 'set local role authenticated';perform public.attendance_admin('revoke',jsonb_build_object('device_id',dev));execute 'reset role';
 execute 'set local role service_role';
 blocked:=false;begin perform public.attendance_device_api('report',token,jsonb_build_object('boot_at',boot));exception when sqlstate 'PT401' then blocked:=true;end;
 execute 'reset role';if not blocked then raise exception 'Revoked device accepted';end if;
 -- Exercise the scheduler/outbox in explicit dry-run mode: no token read and no HTTP request.
 update attendance_private.devices set active=true where id=dev;
 update attendance_private.branches set opening='00:00',closing='23:59',monitor_from=d where branch_id=b;
 insert into public.schedule_cells(work_date,column_id,slot,person_id) values((now() at time zone 'Europe/Moscow')::date,col,1,person);
 delete from attendance_private.days where branch_id=b and day=(now() at time zone 'Europe/Moscow')::date;
 perform attendance_private.ensure_day(b,(now() at time zone 'Europe/Moscow')::date);
 perform attendance_private.tick(true);
 if not exists(select 1 from attendance_private.days where branch_id=b and day=(now() at time zone 'Europe/Moscow')::date and continuous) then raise exception 'Overnight computer not detected';end if;
 -- First actual boot creates one boot notification; repeated heartbeat does not duplicate it.
 perform attendance_private.device_api('report',token,jsonb_build_object('boot_at',now()-interval '1 minute'));
 perform attendance_private.device_api('report',token,jsonb_build_object('boot_at',now()-interval '1 minute'));
 if (select count(*) from attendance_private.outbox where branch_id=b and kind='boot')<>1 then raise exception 'Boot alert duplicated or missing';end if;
 perform attendance_private.tick(true);
 if not exists(select 1 from attendance_private.outbox where branch_id=b and kind='boot' and request_id<0 and attempts=1) then raise exception 'Telegram delivery not queued';end if;
 perform attendance_private.tick(true);
 if exists(select 1 from attendance_private.outbox where branch_id=b and attempts>1) then raise exception 'In-flight Telegram message duplicated';end if;
 -- Ordinary staff must never see employee attendance, pair codes, or device tokens.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.attendance_admin('settings','{}');exception when sqlstate 'PT403' then blocked:=true;end;
 execute 'reset role';if not blocked then raise exception 'Staff accessed admin data';end if;
 if has_function_privilege('anon','public.attendance_admin(text,jsonb)','execute') or has_function_privilege('authenticated','public.attendance_device_api(text,text,jsonb)','execute') or has_table_privilege('authenticated','attendance_private.devices','select') then raise exception 'Excessive access';end if;
end $test$;

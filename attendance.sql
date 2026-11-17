-- Computer start monitoring. All attendance records are private; only administrators can read them.
create schema attendance_private;
revoke all on schema attendance_private from public,anon;
grant usage on schema attendance_private to authenticated,service_role;
create table attendance_private.branches(
 branch_id bigint primary key references public.sales_branches(id),
 enabled boolean not null default true,opening time not null default '10:00',closing time not null default '20:00',
 monitor_from date not null default ((now() at time zone 'Europe/Moscow')::date+1),
 check(opening<closing)
);
create table attendance_private.devices(
 id uuid primary key default gen_random_uuid(),branch_id bigint not null references attendance_private.branches(branch_id),
 label text not null,token_hash text not null unique,active boolean not null default true,
 paired_at timestamptz not null default now(),last_seen timestamptz,last_boot timestamptz,
 version text
);
create unique index attendance_one_device on attendance_private.devices(branch_id) where active;
create table attendance_private.pairs(
 code_hash text primary key,branch_id bigint not null references attendance_private.branches(branch_id),
 expires_at timestamptz not null,used_at timestamptz
);
create table attendance_private.boots(
 device_id uuid not null references attendance_private.devices(id),boot_at timestamptz not null,
 received_at timestamptz not null default now(),primary key(device_id,boot_at)
);
create table attendance_private.days(
 branch_id bigint not null references attendance_private.branches(branch_id),day date not null,
 person_id bigint references public.sales_people(id),person_name text,schedule_status text not null,
 opening time not null,closing time not null,boot_at timestamptz,continuous boolean not null default false,
 excluded boolean not null default false,note text not null default '',primary key(branch_id,day)
);
create table attendance_private.outbox(
 id bigint generated always as identity primary key,branch_id bigint not null,day date not null,
 kind text not null check(kind in ('boot','missing')),chat_id bigint not null,body text not null,
 request_id bigint,sent_at timestamptz,attempts int not null default 0,next_attempt timestamptz not null default now(),error text,
 unique(branch_id,day,kind,chat_id)
);
create index attendance_outbox_due on attendance_private.outbox(next_attempt) where sent_at is null;
create table attendance_private.audit(id bigint generated always as identity primary key,actor uuid,created_at timestamptz not null default now(),branch_id bigint,day date,action text,detail jsonb);
do $$declare t text;begin foreach t in array array['branches','devices','pairs','boots','days','outbox','audit'] loop
 execute format('alter table attendance_private.%I enable row level security',t);
 execute format('create policy private_only on attendance_private.%I for all to authenticated using(false) with check(false)',t);
 end loop;end $$;
revoke all on all tables in schema attendance_private from public,anon,authenticated;

create function attendance_private.ensure_day(p_branch bigint,p_day date) returns void language plpgsql security definer set search_path='' as $$
declare cfg attendance_private.branches;n int;pid bigint;nm text;published boolean;
begin
 select * into cfg from attendance_private.branches where branch_id=p_branch;
 if not found then return;end if;
 select coalesce(m.published,false) into published from public.schedule_months m where m.month=date_trunc('month',p_day)::date;
 select count(distinct c.person_id),min(c.person_id),min(p.name) into n,pid,nm
 from public.schedule_cells c join public.schedule_columns col on col.id=c.column_id join public.sales_people p on p.id=c.person_id
 where c.work_date=p_day and col.branch_id=p_branch and col.is_active and c.slot=1;
 insert into attendance_private.days(branch_id,day,person_id,person_name,schedule_status,opening,closing)
 values(p_branch,p_day,case when published and n=1 then pid end,case when published and n=1 then nm end,
 case when not coalesce(published,false) then 'unpublished' when n=0 then 'empty' when n>1 then 'ambiguous' else 'scheduled' end,cfg.opening,cfg.closing)
 on conflict do nothing;
end $$;

create function attendance_private.enqueue(p_branch bigint,p_day date,p_kind text) returns void language plpgsql security definer set search_path='' as $$
declare d attendance_private.days;b text;body text;minutes int;
begin
 select * into d from attendance_private.days where branch_id=p_branch and day=p_day;
 if not found or d.excluded then return;end if;
 select name into b from public.sales_branches where id=p_branch;
 if p_kind='boot' then
  minutes:=greatest(0,floor(extract(epoch from (d.boot_at-((d.day+d.opening) at time zone 'Europe/Moscow')))/60))::int;
  body:='🟢 '||b||E'\nКомпьютер включён: '||to_char(d.boot_at at time zone 'Europe/Moscow','DD.MM.YYYY HH24:MI')||' МСК'
   ||E'\nПо графику (основной сотрудник): '||coalesce(d.person_name,'не определён')
   ||case when minutes>0 then E'\nПозже начала работы на '||minutes||' мин.' else E'\nВовремя.' end
   ||case when d.boot_at<now()-interval '10 minutes' then E'\nДанные получены с задержкой.' else '' end;
 else
  body:='🟠 '||b||E'\nК началу работы нет данных о включении компьютера.'
   ||E'\nПо графику: '||coalesce(d.person_name,'не определён')
   ||E'\nВозможно опоздание или нет интернета. Время уточнится после получения данных.';
 end if;
 insert into attendance_private.outbox(branch_id,day,kind,chat_id,body)
 select p_branch,p_day,p_kind,r.chat_id,body from public.report_recipients r where r.active and r.chat_id>0
 on conflict(branch_id,day,kind,chat_id) do update set body=excluded.body where attendance_private.outbox.sent_at is null and attendance_private.outbox.request_id is null;
end $$;

create function attendance_private.device_api(p_action text,p_token text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare pair attendance_private.pairs;dev attendance_private.devices;tok text;boot timestamptz;v_day date;cfg attendance_private.branches;now_local timestamp:=now() at time zone 'Europe/Moscow';inserted int;
begin
 if p_action='pair' then
  if length(coalesce(p_payload->>'code',''))<>32 then raise sqlstate 'PT401' using message='Неверный код';end if;
  select * into pair from attendance_private.pairs where code_hash=encode(extensions.digest(p_payload->>'code','sha256'),'hex') and used_at is null and expires_at>now() for update;
  if not found then raise sqlstate 'PT401' using message='Код истёк или уже использован';end if;
  perform pg_advisory_xact_lock(hashtextextended('attendance:'||pair.branch_id,0));
  if exists(select 1 from attendance_private.devices where branch_id=pair.branch_id and active) then raise exception 'Сначала отключите прежний компьютер в админке';end if;
  tok:=encode(extensions.gen_random_bytes(32),'hex');
  insert into attendance_private.devices(branch_id,label,token_hash) values(pair.branch_id,left(coalesce(nullif(p_payload->>'label',''),'Компьютер филиала'),100),encode(extensions.digest(tok,'sha256'),'hex')) returning * into dev;
  update attendance_private.pairs set used_at=now() where code_hash=pair.code_hash;
  return jsonb_build_object('token',tok,'device_id',dev.id,'branch',(select name from public.sales_branches where id=dev.branch_id));
 end if;
 if p_action<>'report' or coalesce(p_token,'')!~'^[a-f0-9]{64}$' then raise sqlstate 'PT401' using message='Нет доступа компьютера';end if;
 select * into dev from attendance_private.devices where token_hash=encode(extensions.digest(p_token,'sha256'),'hex') and active for update;
 if not found then raise sqlstate 'PT401' using message='Компьютер отключён';end if;
 select * into cfg from attendance_private.branches where branch_id=dev.branch_id;
 boot:=(p_payload->>'boot_at')::timestamptz;
 if boot is null or boot>now()+interval '2 minutes' or boot<'2000-01-01'::timestamptz then raise exception 'Некорректное время включения';end if;
 update attendance_private.devices set last_seen=now(),last_boot=greatest(last_boot,boot),version=left(p_payload->>'version',20) where id=dev.id;
 insert into attendance_private.boots(device_id,boot_at) values(dev.id,boot) on conflict do nothing;
 get diagnostics inserted=row_count;
 v_day:=(boot at time zone 'Europe/Moscow')::date;
 perform attendance_private.ensure_day(dev.branch_id,v_day);
 -- Only the earliest boot before closing is an arrival. Restarts never create new messages.
 if (boot at time zone 'Europe/Moscow')::time<cfg.closing then
  update attendance_private.days set boot_at=least(boot_at,boot),continuous=false where branch_id=dev.branch_id and days.day=v_day;
 end if;
 if cfg.enabled and v_day>=cfg.monitor_from and v_day=now_local::date and now_local::time<cfg.closing
    and exists(select 1 from attendance_private.days where branch_id=dev.branch_id and days.day=v_day and boot_at is not null)
 then perform attendance_private.enqueue(dev.branch_id,v_day,'boot');end if;
 -- A computer left on overnight does not establish the employee's arrival.
 if v_day<now_local::date and cfg.enabled then
  perform attendance_private.ensure_day(dev.branch_id,now_local::date);
  update attendance_private.days set continuous=true where branch_id=dev.branch_id and days.day=now_local::date and boot_at is null;
 end if;
 return jsonb_build_object('saved',true,'new_boot',inserted=1,'server_time',now());
end $$;

create function attendance_private.tick(p_dry_run boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare cfg attendance_private.branches;v_dayrow attendance_private.days;r attendance_private.outbox;response record;tok text;local_now timestamp:=now() at time zone 'Europe/Moscow';rid bigint;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('attendance:tick',0)) then return;end if;
 for cfg in select b.* from attendance_private.branches b where enabled and monitor_from<=local_now::date and exists(select 1 from attendance_private.devices dev where dev.branch_id=b.branch_id and dev.active) loop
  perform attendance_private.ensure_day(cfg.branch_id,local_now::date);
  if exists(select 1 from attendance_private.devices dev where dev.branch_id=cfg.branch_id and dev.active and dev.last_seen>now()-interval '12 minutes' and (dev.last_boot at time zone 'Europe/Moscow')::date<local_now::date) then
   update attendance_private.days set continuous=true where branch_id=cfg.branch_id and day=local_now::date and boot_at is null;
  end if;
  select * into v_dayrow from attendance_private.days where branch_id=cfg.branch_id and day=local_now::date;
  if local_now::time>=cfg.opening+interval '2 minutes' and local_now::time<cfg.closing and v_dayrow.schedule_status='scheduled' and v_dayrow.boot_at is null and not v_dayrow.continuous then
   perform attendance_private.enqueue(cfg.branch_id,local_now::date,'missing');
  end if;
 end loop;
 -- Inspect actual Telegram responses before marking a message delivered.
 for r in select * from attendance_private.outbox where sent_at is null and request_id is not null loop
  select * into response from net._http_response where id=r.request_id;
  if found then
   if response.status_code=200 and case when pg_input_is_valid(response.content,'jsonb') then response.content::jsonb->>'ok'='true' else false end then
    update attendance_private.outbox set sent_at=now(),error=null where id=r.id;
   else update attendance_private.outbox set request_id=null,error='Telegram не подтвердил доставку',next_attempt=now()+interval '10 minutes' where id=r.id;end if;
  elsif r.next_attempt<now()-interval '3 minutes' then
   update attendance_private.outbox set request_id=null,error='Нет подтверждения доставки',next_attempt=now()+interval '10 minutes' where id=r.id;
  end if;
 end loop;
 if not p_dry_run then
  select decrypted_secret into tok from vault.decrypted_secrets where name='telegram_bot_token';
  if tok is null then return;end if;
 end if;
 for r in select o.* from attendance_private.outbox o join attendance_private.branches b using(branch_id)
 where o.sent_at is null and o.request_id is null and o.next_attempt<=now() and o.attempts<12 and b.enabled
 and o.day=local_now::date and local_now::time<b.closing
 and (o.kind<>'missing' or exists(select 1 from attendance_private.days d where d.branch_id=o.branch_id and d.day=o.day and d.boot_at is null and not d.continuous))
 order by o.id limit 20 for update of o skip locked loop
  if p_dry_run then rid:=-r.id; else
  rid:=net.http_post(url:='https://api.telegram.org/bot'||tok||'/sendMessage',headers:='{"Content-Type":"application/json"}'::jsonb,body:=jsonb_build_object('chat_id',r.chat_id,'text',r.body),timeout_milliseconds:=10000);
  end if;
  update attendance_private.outbox set request_id=rid,attempts=attempts+1,next_attempt=now()+interval '2 minutes' where id=r.id;
 end loop;
 -- Keep only bounded technical boot history; daily summaries remain.
 delete from attendance_private.boots where received_at<now()-interval '90 days';
 delete from attendance_private.pairs where expires_at<now()-interval '1 day';
end $$;

create function attendance_private.admin(p_action text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare b bigint;code text;from_day date;to_day date;
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор';end if;
 if p_action='settings' then
  return jsonb_build_object('branches',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'enabled',coalesce(b.enabled,false),'opening',coalesce(b.opening,'10:00'),'closing',coalesce(b.closing,'20:00'),'monitor_from',coalesce(b.monitor_from,(now() at time zone 'Europe/Moscow')::date+1)) order by s.name),'[]') from public.sales_branches s left join attendance_private.branches b on b.branch_id=s.id where s.is_active and not s.is_test and not s.is_workshop),
  'devices',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'branch_id',d.branch_id,'label',d.label,'active',d.active,'last_seen',d.last_seen,'last_boot',d.last_boot,'version',d.version) order by d.paired_at desc),'[]') from attendance_private.devices d));
 elsif p_action='save' then
  b:=(p_payload->>'branch_id')::bigint;
  if not exists(select 1 from public.sales_branches where id=b and is_active and not is_test and not is_workshop) then raise exception 'Выберите рабочий филиал';end if;
  insert into attendance_private.branches(branch_id,enabled,opening,closing,monitor_from)
  values(b,(p_payload->>'enabled')::boolean,(p_payload->>'opening')::time,(p_payload->>'closing')::time,(p_payload->>'monitor_from')::date)
  on conflict(branch_id) do update set enabled=excluded.enabled,opening=excluded.opening,closing=excluded.closing,monitor_from=excluded.monitor_from;
 elsif p_action='pair' then
  b:=(p_payload->>'branch_id')::bigint;
  if not exists(select 1 from attendance_private.branches where branch_id=b and enabled) then raise exception 'Сначала сохраните включённый учёт филиала';end if;
  if exists(select 1 from attendance_private.devices where branch_id=b and active) then raise exception 'Сначала отключите прежний компьютер';end if;
  update attendance_private.pairs set used_at=now() where branch_id=b and used_at is null;
  code:=encode(extensions.gen_random_bytes(16),'hex');
  insert into attendance_private.pairs(code_hash,branch_id,expires_at) values(encode(extensions.digest(code,'sha256'),'hex'),b,now()+interval '15 minutes');
  return jsonb_build_object('code',code,'expires_in_minutes',15);
 elsif p_action='revoke' then
  update attendance_private.devices set active=false where id=(p_payload->>'device_id')::uuid;
 elsif p_action='exclude' then
  update attendance_private.days set excluded=(p_payload->>'excluded')::boolean,note=left(coalesce(p_payload->>'note',''),500) where branch_id=(p_payload->>'branch_id')::bigint and day=(p_payload->>'day')::date;
 elsif p_action='report' then
  from_day:=(p_payload->>'from')::date;to_day:=(p_payload->>'to')::date;
  if from_day is null or to_day is null or to_day<from_day or to_day-from_day>366 then raise exception 'Выберите период до 366 дней';end if;
  -- Materialize missing days only since monitoring was enabled and only for paired branches.
  insert into attendance_private.days(branch_id,day,person_id,person_name,schedule_status,opening,closing)
  select b.branch_id,d::date,case when m.published and a.n=1 then a.pid end,case when m.published and a.n=1 then a.nm end,
  case when not coalesce(m.published,false) then 'unpublished' when a.n=0 then 'empty' when a.n>1 then 'ambiguous' else 'scheduled' end,b.opening,b.closing
  from attendance_private.branches b cross join lateral generate_series(greatest(from_day,b.monitor_from)::timestamp,least(to_day,(now() at time zone 'Europe/Moscow')::date)::timestamp,'1 day') d
  left join public.schedule_months m on m.month=date_trunc('month',d)::date
  cross join lateral(select count(distinct c.person_id) n,min(c.person_id) pid,min(p.name) nm from public.schedule_cells c join public.schedule_columns col on col.id=c.column_id join public.sales_people p on p.id=c.person_id where c.work_date=d::date and col.branch_id=b.branch_id and col.is_active and c.slot=1) a
  where exists(select 1 from attendance_private.devices dev where dev.branch_id=b.branch_id)
  on conflict do nothing;
  return jsonb_build_object('days',(select coalesce(jsonb_agg(jsonb_build_object('branch_id',d.branch_id,'branch',s.name,'day',d.day,'person_id',d.person_id,'person',d.person_name,'schedule_status',d.schedule_status,'opening',d.opening,'boot_at',d.boot_at,'received_at',(select min(v.received_at) from attendance_private.boots v join attendance_private.devices dev on dev.id=v.device_id where dev.branch_id=d.branch_id and v.boot_at=d.boot_at),'continuous',d.continuous,'excluded',d.excluded,'note',d.note,'minutes_late',case when d.boot_at is not null then greatest(0,floor(extract(epoch from (d.boot_at-((d.day+d.opening) at time zone 'Europe/Moscow')))/60))::int end,'counted',d.person_id is not null and d.boot_at is not null and not d.excluded and d.day>=b.monitor_from) order by d.day desc,s.name),'[]') from attendance_private.days d join attendance_private.branches b using(branch_id) join public.sales_branches s on s.id=d.branch_id where d.day between from_day and to_day),
  'delivery_errors',(select count(*) from attendance_private.outbox where sent_at is null and error is not null and day between from_day and to_day));
 else raise exception 'Неизвестное действие';end if;
 insert into attendance_private.audit(actor,branch_id,day,action,detail) values(auth.uid(),nullif(p_payload->>'branch_id','')::bigint,nullif(p_payload->>'day','')::date,p_action,p_payload-'code');
 return jsonb_build_object('saved',true);
end $$;

create function public.attendance_admin(p_action text,p_payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select attendance_private.admin(p_action,p_payload)$$;
create function public.attendance_device_api(p_action text,p_token text,p_payload jsonb) returns jsonb language sql security invoker set search_path='' as $$select attendance_private.device_api(p_action,p_token,p_payload)$$;
revoke all on all functions in schema attendance_private from public,anon,authenticated;
grant execute on function attendance_private.admin(text,jsonb) to authenticated;
grant execute on function attendance_private.device_api(text,text,jsonb) to service_role;
revoke all on function public.attendance_admin(text,jsonb),public.attendance_device_api(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.attendance_admin(text,jsonb) to authenticated;
grant execute on function public.attendance_device_api(text,text,jsonb) to service_role;
select cron.schedule('attendance-monitor','* * * * *','select attendance_private.tick()');

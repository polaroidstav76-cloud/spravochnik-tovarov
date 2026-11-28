CREATE OR REPLACE FUNCTION attendance_private.enqueue(p_branch bigint, p_day date, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d attendance_private.days;b text;body text;minutes int;
begin
 if p_kind<>'missing' then return;end if;
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
end $function$
;
CREATE OR REPLACE FUNCTION attendance_private.tick(p_dry_run boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   if response.status_code=200 and (case when pg_input_is_valid(response.content,'jsonb') then response.content::jsonb->>'ok'='true' else false end) then
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
 where o.kind='missing' and o.sent_at is null and o.request_id is null and o.next_attempt<=now() and o.attempts<12 and b.enabled
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
end $function$
;

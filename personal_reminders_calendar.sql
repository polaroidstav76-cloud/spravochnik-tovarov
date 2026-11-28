alter table public.personal_reminders add column schedule_kind text not null default 'daily' check(schedule_kind in ('daily','weekly','monthly','month_last','internet_collect'));
alter table public.personal_reminders add column schedule_day integer;
CREATE OR REPLACE FUNCTION public.personal_reminders_send()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tz constant text:='Europe/Moscow';
  d date:=(now() at time zone tz)::date;
  t time:=(now() at time zone tz)::time;
  v_token text; r record; v_req bigint; n int:=0;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name='telegram_bot_token';
  if v_token is null then return 0; end if;
  for r in
    select p.* from public.personal_reminders p
    where p.active
      and case p.schedule_kind
        when 'daily' then true
        when 'weekly' then extract(isodow from d)=p.schedule_day
        when 'monthly' then extract(day from d)=p.schedule_day
        when 'month_last' then d=(date_trunc('month',d)+interval '1 month - 1 day')::date
        when 'internet_collect' then extract(day from d)=case when extract(month from d)=2 then 27 else 29 end
        else false end
      and p.remind_at<=t and t<p.remind_at+interval '3 hours'
      -- уже доставлено сегодня (Telegram ответил 200)?
      and not exists (select 1 from public.personal_reminder_log l join net._http_response h on h.id=l.request_id
                      where l.reminder_id=p.id and l.day=d and h.status_code=200)
      -- отправка ещё в пути (меньше 2 минут назад)?
      and not exists (select 1 from public.personal_reminder_log l
                      where l.reminder_id=p.id and l.day=d and l.created_at>now()-interval '2 minutes'
                        and not exists (select 1 from net._http_response h where h.id=l.request_id))
      and (select count(*) from public.personal_reminder_log l where l.reminder_id=p.id and l.day=d)<8
  loop
    v_req:=net.http_post(
      url:='https://api.telegram.org/bot'||v_token||'/sendMessage',
      headers:='{"Content-Type":"application/json"}'::jsonb,
      body:=jsonb_build_object('chat_id',r.chat_id,'text',r.text),
      timeout_milliseconds:=30000);
    insert into public.personal_reminder_log(reminder_id,day,request_id) values (r.id,d,v_req);
    n:=n+1;
  end loop;
  return n;
end $function$;
update public.personal_reminders set active=false where text ilike '%отложить деньги на ДР%';
insert into public.personal_reminders(chat_id,remind_at,text,schedule_kind,schedule_day)
select owner.chat_id,r.tm::time,r.msg,r.kind,r.dy from
(select chat_id from public.personal_reminders where text ilike '%отложить деньги на ДР%' order by id limit 1) owner
cross join (values
('09:00','⏰ Напоминание: взять оплату за интернет с Белого города','internet_collect',null::int),
('09:00','⏰ Напоминание: оплатить интернет','month_last',null::int),
('09:00','⏰ Напоминание: взять оплату за уборку с салона красоты','monthly',20),
('09:00','🛒 Сделай закупку','weekly',2),
('13:00','🛒 Сделай закупку','weekly',2),
('18:00','🛒 Сделай закупку','weekly',2)
)r(tm,msg,kind,dy);

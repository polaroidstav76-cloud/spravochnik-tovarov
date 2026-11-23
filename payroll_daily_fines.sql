create schema if not exists payroll_private;
revoke all on schema payroll_private from public,anon;
grant usage on schema payroll_private to authenticated,service_role;
create table payroll_private.fines(
 id uuid primary key default gen_random_uuid(),person_id bigint not null references public.sales_people(id),
 amount numeric(12,2) not null check(amount>0),occurred_on date not null default (now() at time zone 'Europe/Moscow')::date,
 reason text not null default '',created_at timestamptz not null default now(),created_by uuid,telegram_chat_id bigint,telegram_message_id bigint,
 revoked_at timestamptz,revoked_by uuid,unique(telegram_chat_id,telegram_message_id)
);
create index on payroll_private.fines(person_id,occurred_on);
alter table payroll_private.fines enable row level security;
revoke all on payroll_private.fines from public,anon,authenticated;
create table payroll_private.fine_sessions(chat_id bigint primary key,step text not null,person_id bigint,amount numeric(12,2),last_message_id bigint not null,expires_at timestamptz not null);
alter table payroll_private.fine_sessions enable row level security;
revoke all on payroll_private.fine_sessions from public,anon,authenticated;
-- The UI never receives colleagues' rates under an employee login.
alter policy sales_pay_rates_select_public on public.sales_pay_rates using(public.is_admin() or exists(select 1 from public.staff_accounts a join public.sales_employees e on e.person_id=a.person_id where a.user_id=auth.uid() and a.active and e.id=employee_id));
create function payroll_private.report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare me bigint;admin boolean;result jsonb;fine_rows jsonb;
begin
 if not public.is_staff() then raise sqlstate 'PT403' using message='Требуется вход сотрудника';end if;
 admin:=public.is_admin();select person_id into me from public.staff_accounts where user_id=auth.uid() and active;
 if not admin and me is null then raise sqlstate 'PT403' using message='Логин не связан с сотрудником. Обратитесь к администратору';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Выберите период до 367 дней';end if;
 with members as (
  select distinct on (s.id,coalesce('p:'||e.person_id,'e:'||e.id)) s.id shift_id,s.started_at,(s.started_at at time zone 'Europe/Moscow')::date work_day,s.no_pay,
   e.person_id,coalesce('p:'||e.person_id,'e:'||e.id) person_key,coalesce(pp.name,e.name) name,
   coalesce(r.shift_rate,0) shift_rate,coalesce(r.retouch_rate,100) retouch_rate,
   (se.is_lead or (select count(*) from public.sales_shift_employees where shift_id=s.id)=1) retouch_lead
  from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id join public.sales_shift_employees se on se.shift_id=s.id
  join public.sales_employees e on e.id=se.employee_id left join public.sales_people pp on pp.id=e.person_id
  left join lateral(select pr.shift_rate,pr.retouch_rate from public.sales_pay_rates pr where pr.employee_id=e.id and pr.branch_id=s.branch_id and pr.is_active order by pr.id desc limit 1)r on true
  where s.started_at>=(p_from::timestamp at time zone 'Europe/Moscow') and s.started_at<((p_to+1)::timestamp at time zone 'Europe/Moscow') and not coalesce(b.is_test,false) and (admin or e.person_id=me)
  order by s.id,coalesce('p:'||e.person_id,'e:'||e.id),coalesce(r.shift_rate,0) desc,se.is_lead desc
 ),days as (
  select distinct on(person_key,work_day) * from members where not coalesce(no_pay,false) order by person_key,work_day,shift_rate desc,started_at,shift_id
 ),wages as (select person_key,count(*) shifts,sum(shift_rate) shift_pay from days group by person_key),
 stats as (select person_key,count(*) filter(where coalesce(no_pay,false)) free_shifts,count(*) filter(where not coalesce(no_pay,false)) raw_shifts from members group by person_key),
 retouch as (
  select m.person_key,sum(i.quantity) quantity,sum(i.quantity*m.retouch_rate) pay
  from members m join public.sales s on s.shift_id=m.shift_id and s.status='completed' and s.payment_status<>'unpaid'
  join public.sale_items i on i.sale_id=s.id and i.item_type='service' and i.item_name ~* 'ретуш' where m.retouch_lead group by m.person_key
 ),deductions as (
  select 'p:'||f.person_id person_key,sum(f.amount) amount from payroll_private.fines f where f.revoked_at is null and f.occurred_on between p_from and p_to and (admin or f.person_id=me) group by f.person_id
 ),people as (
  select distinct person_key,person_id,name from members union select 'p:'||p.id,p.id,p.name from public.sales_people p where (admin or p.id=me) and exists(select 1 from deductions d where d.person_key='p:'||p.id)
 )
 select coalesce(jsonb_agg(jsonb_build_object('person_id',p.person_id,'name',p.name,'shifts',coalesce(w.shifts,0),'shift_pay',coalesce(w.shift_pay,0),'free_shifts',coalesce(s.free_shifts,0),'duplicates',greatest(coalesce(s.raw_shifts,0)-coalesce(w.shifts,0),0),'retouches',coalesce(r.quantity,0),'retouch_pay',coalesce(r.pay,0),'fines',coalesce(d.amount,0),'total',coalesce(w.shift_pay,0)+coalesce(r.pay,0)-coalesce(d.amount,0)) order by p.name),'[]'::jsonb) into result
 from people p left join wages w using(person_key) left join stats s using(person_key) left join retouch r using(person_key) left join deductions d using(person_key);
 select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'person_id',f.person_id,'name',p.name,'amount',f.amount,'date',f.occurred_on,'reason',f.reason,'revoked',f.revoked_at is not null) order by f.occurred_on desc,f.created_at desc),'[]'::jsonb) into fine_rows from payroll_private.fines f join public.sales_people p on p.id=f.person_id where f.occurred_on between p_from and p_to and (admin or f.person_id=me);
 return jsonb_build_object('rows',result,'fines',fine_rows,'admin',admin);
end $$;
create function public.payroll_report(p_from date,p_to date) returns jsonb language sql security invoker set search_path='' as $$select payroll_private.report(p_from,p_to)$$;
create function payroll_private.revoke_fine(p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Отменить штраф может только администратор';end if;
 update payroll_private.fines set revoked_at=coalesce(revoked_at,now()),revoked_by=coalesce(revoked_by,auth.uid()) where id=p_id;return found;
end $$;
create function public.payroll_fine_revoke(p_id uuid) returns boolean language sql security invoker set search_path='' as $$select payroll_private.revoke_fine(p_id)$$;
revoke all on function payroll_private.report(date,date),public.payroll_report(date,date),payroll_private.revoke_fine(uuid),public.payroll_fine_revoke(uuid) from public,anon;
grant execute on function payroll_private.report(date,date),public.payroll_report(date,date),payroll_private.revoke_fine(uuid),public.payroll_fine_revoke(uuid) to authenticated;
create function payroll_private.telegram_flow(p_chat_id bigint,p_message_id bigint,p_action text,p_text text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare s payroll_private.fine_sessions%rowtype;person public.sales_people%rowtype;matches jsonb;n integer;value numeric;fid uuid;existing payroll_private.fines%rowtype;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 if not exists(select 1 from public.report_recipients where chat_id=p_chat_id and active) then return jsonb_build_object('status','inactive');end if;
 perform pg_advisory_xact_lock(hashtextextended('payroll-fine:'||p_chat_id,0));
 select * into existing from payroll_private.fines where telegram_chat_id=p_chat_id and telegram_message_id=p_message_id;
 if found then select * into person from public.sales_people where id=existing.person_id;return jsonb_build_object('status','saved','name',person.name,'amount',existing.amount);end if;
 select * into s from payroll_private.fine_sessions where chat_id=p_chat_id for update;
 if s.last_message_id>=p_message_id then return jsonb_build_object('status','ignored');end if;
 if p_action='cancel' then delete from payroll_private.fine_sessions where chat_id=p_chat_id;return jsonb_build_object('status',case when found then 'cancelled' else 'inactive' end);end if;
 if p_action='start' then
  insert into payroll_private.fine_sessions values(p_chat_id,'name',null,null,p_message_id,now()+interval '30 minutes') on conflict(chat_id) do update set step='name',person_id=null,amount=null,last_message_id=excluded.last_message_id,expires_at=excluded.expires_at;
  return jsonb_build_object('status','name');
 end if;
 if s.chat_id is null then return jsonb_build_object('status','inactive');end if;
 if s.expires_at<now() then delete from payroll_private.fine_sessions where chat_id=p_chat_id;return jsonb_build_object('status','expired');end if;
 update payroll_private.fine_sessions set last_message_id=p_message_id where chat_id=p_chat_id;
 if s.step='name' then
  select count(*),jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name,p.id) into n,matches from public.sales_people p where p.is_active and (lower(trim(p.name))=lower(trim(p_text)) or (p_text ~ '^#[0-9]+$' and '#'||p.id=p_text));
  if n=0 then select count(*),jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name,p.id) into n,matches from public.sales_people p where p.is_active and position(lower(trim(p_text)) in lower(p.name))>0 and length(trim(p_text))>=2;end if;
  if n=1 then select * into person from public.sales_people where id=(matches->0->>'id')::bigint;update payroll_private.fine_sessions set person_id=person.id,step='amount' where chat_id=p_chat_id;return jsonb_build_object('status','amount','name',person.name);end if;
  return jsonb_build_object('status','choose','people',coalesce((select jsonb_agg(x) from(select value x from jsonb_array_elements(matches) limit 30)q),'[]'::jsonb));
 elsif s.step='amount' then
  if trim(p_text) !~ '^[0-9]+([.,][0-9]{1,2})?$' then return jsonb_build_object('status','bad_amount');end if;
  value:=replace(trim(p_text),',','.')::numeric;if value<=0 or value>999999999 then return jsonb_build_object('status','bad_amount');end if;
  select * into person from public.sales_people where id=s.person_id and is_active;if not found then delete from payroll_private.fine_sessions where chat_id=p_chat_id;return jsonb_build_object('status','expired');end if;
  update payroll_private.fine_sessions set amount=value,step='confirm' where chat_id=p_chat_id;
  return jsonb_build_object('status','confirm','name',person.name,'amount',value);
 elsif s.step='confirm' then
  if p_action<>'confirm' then return jsonb_build_object('status','await_confirm');end if;
  select * into person from public.sales_people where id=s.person_id and is_active;if not found then return jsonb_build_object('status','expired');end if;
  insert into payroll_private.fines(person_id,amount,telegram_chat_id,telegram_message_id) values(s.person_id,s.amount,p_chat_id,p_message_id) returning id into fid;
  delete from payroll_private.fine_sessions where chat_id=p_chat_id;
  return jsonb_build_object('status','saved','id',fid,'name',person.name,'amount',s.amount);
 end if;
 return jsonb_build_object('status','inactive');
end $$;
create function public.telegram_payroll_fine(p_chat_id bigint,p_message_id bigint,p_action text,p_text text default null) returns jsonb language sql security invoker set search_path='' as $$select payroll_private.telegram_flow(p_chat_id,p_message_id,p_action,p_text)$$;
revoke all on function payroll_private.telegram_flow(bigint,bigint,text,text),public.telegram_payroll_fine(bigint,bigint,text,text) from public,anon,authenticated;
grant execute on function payroll_private.telegram_flow(bigint,bigint,text,text),public.telegram_payroll_fine(bigint,bigint,text,text) to service_role;
notify pgrst,'reload schema';

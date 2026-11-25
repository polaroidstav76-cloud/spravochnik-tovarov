-- Training is entered as a cumulative count, separately from ordinary shifts/deposit.
create table payroll_private.training(
 person_id bigint primary key references public.sales_people(id),
 shifts integer not null check(shifts between 0 and 10000),version integer not null default 1,
 updated_at timestamptz not null default now(),updated_by uuid not null,
 paid_at timestamptz,paid_by uuid,paid_amount numeric(12,2),paid_due_on date
);
create table payroll_private.training_audit(
 id bigint generated always as identity primary key,person_id bigint not null references public.sales_people(id),
 actor uuid not null,changed_at timestamptz not null default now(),before_state jsonb,after_state jsonb not null
);
alter table payroll_private.training enable row level security;
alter table payroll_private.training_audit enable row level security;
create policy no_client_access on payroll_private.training for all to anon,authenticated using(false) with check(false);
create policy no_client_access on payroll_private.training_audit for all to anon,authenticated using(false) with check(false);
revoke all on payroll_private.training,payroll_private.training_audit from public,anon,authenticated;

create function payroll_private.training_info(p_person bigint) returns jsonb language sql stable security definer set search_path='' as $$
 with start_date as (
  select min((s.started_at at time zone 'Europe/Moscow')::date) first_day
  from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id
  join public.sales_shift_employees se on se.shift_id=s.id join public.sales_employees e on e.id=se.employee_id
  where e.person_id=p_person and not coalesce(b.is_test,false) and not coalesce(s.no_pay,false)
 ),info as (
  select t.*,p.name,d.first_day first_work_on,coalesce(t.paid_due_on,(d.first_day+interval '1 month')::date) due_on
  from payroll_private.training t join public.sales_people p on p.id=t.person_id cross join start_date d where t.person_id=p_person
 )
 select jsonb_build_object('person_id',person_id,'name',name,'shifts',shifts,'rate',500,'amount',shifts*500,'version',version,
  'first_work_on',first_work_on,'due_on',due_on,'ready',coalesce(due_on<=(now() at time zone 'Europe/Moscow')::date,false),
  'paid',paid_at is not null,'paid_at',paid_at,'paid_amount',paid_amount) from info
$$;

-- Preserve the existing password gate, deposit and fine calculations unchanged.
do $$begin execute replace(pg_get_functiondef('payroll_private.report(date,date)'::regprocedure),'FUNCTION payroll_private.report(','FUNCTION payroll_private.report_before_training(');end $$;
revoke all on function payroll_private.report_before_training(date,date) from public,anon,authenticated;
create or replace function payroll_private.report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m jsonb;me bigint;admin boolean;t record;info jsonb;entries jsonb:='[]';rows jsonb;item jsonb;amount numeric;due date;found_person boolean;
begin
 m:=payroll_private.report_before_training(p_from,p_to);admin:=(m->>'admin')::boolean;rows:=m->'rows';
 select person_id into me from public.staff_accounts where user_id=auth.uid() and active;
 for t in select person_id from payroll_private.training where admin or person_id=me order by person_id loop
  info:=payroll_private.training_info(t.person_id);due:=(info->>'due_on')::date;
  amount:=case when due between p_from and p_to and (info->>'ready')::boolean then (info->>'amount')::numeric else 0 end;
  info:=info||jsonb_build_object('period_amount',amount);entries:=entries||jsonb_build_array(info);
  found_person:=false;
  select coalesce(jsonb_agg(case when (x->>'person_id')::bigint=t.person_id then x||jsonb_build_object('training',amount,'total',(x->>'total')::numeric+amount) else x end),'[]') into rows from jsonb_array_elements(rows) x;
  if amount>0 and not exists(select 1 from jsonb_array_elements(rows) x where (x->>'person_id')::bigint=t.person_id) then
   rows:=rows||jsonb_build_array(jsonb_build_object('person_id',t.person_id,'name',info->>'name','shifts',0,'shift_pay',0,'free_shifts',0,'duplicates',0,'retouches',0,'retouch_pay',0,'fines',0,'deposit',0,'training',amount,'total',amount));
  end if;
 end loop;
 return m||jsonb_build_object('rows',rows,'training',entries,'training_people',case when admin then coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name) from public.sales_people p where p.is_active or exists(select 1 from payroll_private.training tr where tr.person_id=p.id)),'[]'::jsonb) else '[]'::jsonb end);
end $$;

create function payroll_private.training_set(p_person bigint,p_shifts integer,p_expected_version integer) returns boolean language plpgsql security definer set search_path='' as $$
declare old payroll_private.training;next_row payroll_private.training;
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Стажировку указывает только администратор';end if;
 if p_shifts is null or p_shifts not between 0 and 10000 then raise exception 'Укажите целое количество стажировок от 0 до 10000';end if;
 perform pg_advisory_xact_lock(hashtextextended('payroll-training:'||p_person::text,0));
 select * into old from payroll_private.training where person_id=p_person for update;
 if coalesce(old.version,0) is distinct from p_expected_version then raise sqlstate 'PT409' using message='Стажировка уже изменена. Обновите зарплату и повторите';end if;
 if old.paid_at is not null then raise exception 'Стажировка уже выплачена. Перед изменением верните статус «Не выплачено»';end if;
 insert into payroll_private.training(person_id,shifts,updated_by) values(p_person,p_shifts,auth.uid())
 on conflict(person_id) do update set shifts=excluded.shifts,version=training.version+1,updated_at=now(),updated_by=auth.uid() returning * into next_row;
 insert into payroll_private.training_audit(person_id,actor,before_state,after_state) values(p_person,auth.uid(),case when old.person_id is not null then to_jsonb(old) end,to_jsonb(next_row));
 return true;
end $$;
create function payroll_private.training_paid(p_person bigint,p_paid boolean,p_expected_version integer) returns boolean language plpgsql security definer set search_path='' as $$
declare old payroll_private.training;next_row payroll_private.training;info jsonb;
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Выплату стажировки отмечает только администратор';end if;
 if p_paid is null then raise exception 'Укажите статус выплаты';end if;
 perform pg_advisory_xact_lock(hashtextextended('payroll-training:'||p_person::text,0));
 select * into old from payroll_private.training where person_id=p_person for update;
 if not found then raise exception 'Стажировка не внесена';end if;
 if old.version is distinct from p_expected_version then raise sqlstate 'PT409' using message='Стажировка уже изменена. Обновите зарплату';end if;
 if p_paid=(old.paid_at is not null) then return true;end if;
 info:=payroll_private.training_info(p_person);
 if p_paid and (not (info->>'ready')::boolean or old.shifts=0) then raise exception 'Стажировка доступна к выплате через месяц после первой рабочей смены';end if;
 update payroll_private.training set paid_at=case when p_paid then now() end,paid_by=case when p_paid then auth.uid() end,
 paid_amount=case when p_paid then old.shifts*500 end,paid_due_on=case when p_paid then (info->>'due_on')::date end,
 version=version+1,updated_at=now(),updated_by=auth.uid() where person_id=p_person returning * into next_row;
 insert into payroll_private.training_audit(person_id,actor,before_state,after_state) values(p_person,auth.uid(),to_jsonb(old),to_jsonb(next_row));
 return true;
end $$;
create function public.payroll_training_set(p_person bigint,p_shifts integer,p_expected_version integer) returns boolean language sql security invoker set search_path='' as $$select payroll_private.training_set(p_person,p_shifts,p_expected_version)$$;
create function public.payroll_training_paid(p_person bigint,p_paid boolean,p_expected_version integer) returns boolean language sql security invoker set search_path='' as $$select payroll_private.training_paid(p_person,p_paid,p_expected_version)$$;
revoke all on function payroll_private.training_info(bigint),payroll_private.training_set(bigint,integer,integer),payroll_private.training_paid(bigint,boolean,integer),public.payroll_training_set(bigint,integer,integer),public.payroll_training_paid(bigint,boolean,integer) from public,anon,authenticated;
grant execute on function payroll_private.training_set(bigint,integer,integer),payroll_private.training_paid(bigint,boolean,integer),public.payroll_training_set(bigint,integer,integer),public.payroll_training_paid(bigint,boolean,integer) to authenticated;
notify pgrst,'reload schema';

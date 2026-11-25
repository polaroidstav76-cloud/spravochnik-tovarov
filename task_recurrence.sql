create schema task_recur_private;
revoke all on schema task_recur_private from public,anon;
grant usage on schema task_recur_private to authenticated;
create table task_recur_private.rules(
 id bigint generated always as identity primary key,target text not null check(target in('branch','person')),
 branch_id bigint references public.sales_branches(id),person_id bigint references public.sales_people(id),
 title text not null check(length(trim(title)) between 1 and 500),description text not null default '' check(length(description)<=4000),
 kind text not null check(kind in('days','weeks','months')),every integer not null check(every between 1 and 3650),
 weekdays integer[] not null default '{}',month_day integer not null default 1 check(month_day between 1 and 31),
 starts_on date not null,ends_on date,next_date date,enabled boolean not null default true,version integer not null default 1,
 created_by uuid not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 check((target='branch' and branch_id is not null and person_id is null) or(target='person' and person_id is not null and branch_id is null)),
 check(ends_on is null or ends_on>=starts_on),check(weekdays<@array[1,2,3,4,5,6,7]),check(kind<>'weeks' or cardinality(weekdays)>0),
 check(kind<>'weeks' or every<=520),check(kind<>'months' or every<=120)
);
create index task_recur_due on task_recur_private.rules(next_date) where enabled;
create index task_recur_branch on task_recur_private.rules(branch_id);
create index task_recur_person on task_recur_private.rules(person_id);
alter table public.sales_shift_tasks add column recurrence_id bigint references task_recur_private.rules(id);
alter table public.sales_person_tasks add column recurrence_id bigint references task_recur_private.rules(id);
create unique index sales_shift_tasks_recur_date on public.sales_shift_tasks(recurrence_id,task_date);
create unique index sales_person_tasks_recur_date on public.sales_person_tasks(recurrence_id,start_date);
create table task_recur_private.occurrences(
 rule_id bigint not null references task_recur_private.rules(id),due_on date not null,
 branch_task_id bigint references public.sales_shift_tasks(id) on delete set null,
 person_task_id bigint references public.sales_person_tasks(id) on delete set null,
 created_at timestamptz not null default now(),primary key(rule_id,due_on)
);
create index task_recur_occ_branch on task_recur_private.occurrences(branch_task_id);
create index task_recur_occ_person on task_recur_private.occurrences(person_task_id);
alter table task_recur_private.rules enable row level security;
alter table task_recur_private.occurrences enable row level security;
create policy no_clients on task_recur_private.rules for all to anon,authenticated using(false) with check(false);
create policy no_clients on task_recur_private.occurrences for all to anon,authenticated using(false) with check(false);
revoke all on all tables in schema task_recur_private from public,anon,authenticated;

create function task_recur_private.next_on(r task_recur_private.rules,p_from date) returns date language plpgsql immutable set search_path='' as $$
declare base date:=greatest(r.starts_on,p_from);candidate date;anchor date;n integer;days integer;wd integer;attempt integer;
begin
 if r.ends_on is not null and base>r.ends_on then return null;end if;
 if r.kind='days' then
  n:=((base-r.starts_on)+r.every-1)/r.every;candidate:=r.starts_on+n*r.every;
 elsif r.kind='weeks' then
  anchor:=date_trunc('week',r.starts_on::timestamp)::date;n:=(date_trunc('week',base::timestamp)::date-anchor)/7;n:=((n+r.every-1)/r.every)*r.every;
  for attempt in 1..2 loop
   for wd in select distinct value from unnest(r.weekdays) value order by value loop
    candidate:=anchor+n*7+wd-1;if candidate>=base then exit;end if;candidate:=null;
   end loop;
   exit when candidate is not null;n:=n+r.every;
  end loop;
 else
  anchor:=date_trunc('month',r.starts_on::timestamp)::date;
  n:=(extract(year from base)::integer-extract(year from anchor)::integer)*12+extract(month from base)::integer-extract(month from anchor)::integer;
  n:=((n+r.every-1)/r.every)*r.every;
  for attempt in 1..2 loop
   candidate:=(anchor+make_interval(months=>n))::date;days:=extract(day from candidate+interval '1 month'-interval '1 day')::integer;
   candidate:=candidate+least(r.month_day,days)-1;if candidate>=base then exit;end if;candidate:=null;n:=n+r.every;
  end loop;
 end if;
 if r.ends_on is not null and candidate>r.ends_on then return null;end if;return candidate;
end $$;

create function task_recur_private.generate(p_until date default (now() at time zone 'Europe/Moscow')::date) returns integer language plpgsql security definer set search_path='' as $$
declare rule task_recur_private.rules;due date;task_id bigint;made integer:=0;iterations integer;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('task-recur-admin',0)) then return 0;end if;
 for rule in select * from task_recur_private.rules r where r.enabled and r.next_date<=p_until order by r.next_date,r.id for update skip locked loop
  if (rule.target='person' and not exists(select 1 from public.sales_people p where p.id=rule.person_id and p.is_active)) or(rule.target='branch' and not exists(select 1 from public.sales_branches b where b.id=rule.branch_id and b.is_active)) then update task_recur_private.rules set enabled=false,version=version+1,updated_at=now() where id=rule.id;continue;end if;
  due:=rule.next_date;iterations:=0;
  while due is not null and due<=p_until and iterations<64 and made<500 loop
   if not exists(select 1 from task_recur_private.occurrences o where o.rule_id=rule.id and o.due_on=due) then
    if rule.target='branch' then
     insert into public.sales_shift_tasks(branch_id,task_date,title,description,recurrence_id) values(rule.branch_id,due,rule.title,nullif(rule.description,''),rule.id) on conflict(recurrence_id,task_date) do update set recurrence_id=excluded.recurrence_id returning id into task_id;
     insert into task_recur_private.occurrences(rule_id,due_on,branch_task_id) values(rule.id,due,task_id);
    else
     insert into public.sales_person_tasks(person_id,start_date,title,description,recurrence_id) values(rule.person_id,due,rule.title,nullif(rule.description,''),rule.id) on conflict(recurrence_id,start_date) do update set recurrence_id=excluded.recurrence_id returning id into task_id;
     insert into task_recur_private.occurrences(rule_id,due_on,person_task_id) values(rule.id,due,task_id);
    end if;made:=made+1;
   end if;
   due:=task_recur_private.next_on(rule,due+1);iterations:=iterations+1;
  end loop;
  update task_recur_private.rules set next_date=due where id=rule.id;exit when made>=500;
 end loop;return made;
end $$;

create function task_recur_private.refresh() returns integer language plpgsql security definer set search_path='' as $$begin
 if not public.is_staff() then raise sqlstate 'PT403' using message='Войдите в свой аккаунт';end if;
 return task_recur_private.generate();
end $$;

create function task_recur_private.manage(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare rule task_recur_private.rules;expected integer:=(p_data->>'version')::integer;today date:=(now() at time zone 'Europe/Moscow')::date;
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Повторяющиеся задания настраивает администратор';end if;
 if p_action='list' then
  return coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('target_name',coalesce(b.name,p.name),'published',(select count(*) from task_recur_private.occurrences o where o.rule_id=r.id),'recent',coalesce((select jsonb_agg(x) from(select o.due_on,coalesce(pt.title,bt.title) title,case when o.person_task_id is not null then pt.completed_at is not null else exists(select 1 from public.sales_shift_task_completions c where c.task_id=o.branch_task_id) end completed from task_recur_private.occurrences o left join public.sales_person_tasks pt on pt.id=o.person_task_id left join public.sales_shift_tasks bt on bt.id=o.branch_task_id where o.rule_id=r.id order by o.due_on desc limit 8)x),'[]')) order by r.created_at desc) from task_recur_private.rules r left join public.sales_branches b on b.id=r.branch_id left join public.sales_people p on p.id=r.person_id),'[]');
 end if;
 perform pg_advisory_xact_lock(hashtextextended('task-recur-admin',0));
 if p_data ? 'id' then select * into rule from task_recur_private.rules where id=(p_data->>'id')::bigint for update;if not found then raise exception 'Повторение не найдено';end if;if rule.version is distinct from expected then raise sqlstate 'PT409' using message='Настройки уже изменены. Обновите список';end if;end if;
 if p_action='toggle' then
  rule.enabled:=(p_data->>'enabled')::boolean;
  update task_recur_private.rules set enabled=rule.enabled,next_date=case when rule.enabled then task_recur_private.next_on(rule,today) else next_date end,version=version+1,updated_at=now() where id=rule.id;
 elsif p_action='save' then
  rule.target:=p_data->>'target';rule.branch_id:=case when rule.target='branch' then (p_data->>'target_id')::bigint end;rule.person_id:=case when rule.target='person' then (p_data->>'target_id')::bigint end;
  rule.title:=trim(p_data->>'title');rule.description:=coalesce(p_data->>'description','');rule.kind:=p_data->>'kind';rule.every:=(p_data->>'every')::integer;
  rule.weekdays:=array(select distinct x::integer from jsonb_array_elements_text(coalesce(p_data->'weekdays','[]')) x order by x::integer);rule.month_day:=coalesce((p_data->>'month_day')::integer,1);
  rule.starts_on:=(p_data->>'starts_on')::date;rule.ends_on:=nullif(p_data->>'ends_on','')::date;rule.enabled:=true;
  if rule.target not in('branch','person') or rule.target is null then raise exception 'Выберите получателя задания';end if;
  if rule.title is null or length(rule.title) not between 1 and 500 then raise exception 'Введите задание — до 500 символов';end if;
  if rule.kind is null or rule.kind not in('days','weeks','months') or rule.every is null or rule.every not between 1 and 3650 or(rule.kind='weeks' and(rule.every>520 or cardinality(rule.weekdays)=0)) or(rule.kind='months' and rule.every>120) or not(rule.weekdays<@array[1,2,3,4,5,6,7]) or rule.month_day not between 1 and 31 then raise exception 'Проверьте периодичность: количество, дни недели и число месяца';end if;
  if rule.starts_on is null or(rule.ends_on is not null and rule.ends_on<rule.starts_on) then raise exception 'Проверьте даты начала и окончания';end if;
  if rule.target='person' and not exists(select 1 from public.sales_people where id=rule.person_id and is_active) or rule.target='branch' and not exists(select 1 from public.sales_branches where id=rule.branch_id and is_active) then raise exception 'Получатель не найден или отключён';end if;
  rule.next_date:=task_recur_private.next_on(rule,greatest(today,rule.starts_on));
  if rule.id is null then
   insert into task_recur_private.rules(target,branch_id,person_id,title,description,kind,every,weekdays,month_day,starts_on,ends_on,next_date,created_by) values(rule.target,rule.branch_id,rule.person_id,rule.title,rule.description,rule.kind,rule.every,rule.weekdays,rule.month_day,rule.starts_on,rule.ends_on,rule.next_date,auth.uid()) returning id into rule.id;
  else
   update task_recur_private.rules set target=rule.target,branch_id=rule.branch_id,person_id=rule.person_id,title=rule.title,description=rule.description,kind=rule.kind,every=rule.every,weekdays=rule.weekdays,month_day=rule.month_day,starts_on=rule.starts_on,ends_on=rule.ends_on,next_date=rule.next_date,enabled=true,version=version+1,updated_at=now() where id=rule.id;
  end if;
 else raise exception 'Неизвестная операция';end if;
 perform task_recur_private.generate();return jsonb_build_object('ok',true,'id',rule.id);
end $$;

-- A recurring branch occurrence is completed once for the branch, rather than again in every new shift.
create function task_recur_private.complete_branch() returns trigger language plpgsql security definer set search_path='' as $$
declare task public.sales_shift_tasks;
begin
 select * into task from public.sales_shift_tasks where id=new.task_id for update;
 if task.recurrence_id is null then return new;end if;
 if not exists(select 1 from public.sales_shifts sh join public.sales_shift_employees se on se.shift_id=sh.id join public.sales_employees e on e.id=se.employee_id where sh.id=new.shift_id and sh.branch_id=task.branch_id and sh.status='open' and e.id=new.completed_by_employee_id) then raise exception 'Отметьте задание в открытой смене этого филиала';end if;
 if not public.is_admin() and not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id join public.staff_accounts a on a.person_id=e.person_id where se.shift_id=new.shift_id and a.user_id=auth.uid() and a.active) then raise sqlstate 'PT403' using message='Подключитесь к смене из своего аккаунта';end if;
 update public.sales_shift_tasks set is_active=false where id=task.id;return new;
end $$;
create trigger recurring_branch_completed after insert or update on public.sales_shift_task_completions for each row execute function task_recur_private.complete_branch();
create function public.tasks_recur_manage(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select task_recur_private.manage(p_action,p_data)$$;
create function public.tasks_recur_refresh() returns integer language sql security invoker set search_path='' as $$select task_recur_private.refresh()$$;
revoke all on all functions in schema task_recur_private from public,anon,authenticated;
revoke all on function public.tasks_recur_manage(text,jsonb),public.tasks_recur_refresh() from public,anon,authenticated;
grant execute on function task_recur_private.manage(text,jsonb),task_recur_private.refresh(),public.tasks_recur_manage(text,jsonb),public.tasks_recur_refresh() to authenticated;
select cron.schedule('recurring-tasks','*/5 * * * *','select task_recur_private.generate();');
notify pgrst,'reload schema';

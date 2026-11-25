create schema task_tracking_private;
revoke all on schema task_tracking_private from public,anon;
grant usage on schema task_tracking_private to authenticated;
create table task_tracking_private.settings(id boolean primary key default true check(id),started_at timestamptz not null default now());
insert into task_tracking_private.settings values(true,now());
create table task_tracking_private.views(
 kind text not null check(kind in('branch','person')),task_id bigint not null,
 branch_task_id bigint references public.sales_shift_tasks(id) on delete cascade,
 person_task_id bigint references public.sales_person_tasks(id) on delete cascade,
 person_id bigint not null references public.sales_people(id),actor uuid not null,name text not null,
 shift_id bigint references public.sales_shifts(id) on delete set null,first_seen timestamptz not null default now(),last_seen timestamptz not null default now(),
 primary key(kind,task_id,person_id),check((kind='branch' and branch_task_id=task_id and person_task_id is null) or(kind='person' and person_task_id=task_id and branch_task_id is null))
);
create index task_tracking_view_branch on task_tracking_private.views(branch_task_id);
create index task_tracking_view_person_task on task_tracking_private.views(person_task_id);
create index task_tracking_view_person on task_tracking_private.views(person_id);
create index task_tracking_view_shift on task_tracking_private.views(shift_id);
create table task_tracking_private.completions(
 id bigint generated always as identity primary key,kind text not null check(kind in('branch','person')),task_id bigint not null,
 branch_task_id bigint references public.sales_shift_tasks(id) on delete cascade,
 person_task_id bigint references public.sales_person_tasks(id) on delete cascade,
 branch_completion_id bigint unique references public.sales_shift_task_completions(id) on delete cascade,
 actor uuid not null,person_id bigint references public.sales_people(id) on delete set null,name text not null,
 shift_id bigint references public.sales_shifts(id) on delete set null,completed_at timestamptz not null,
 check((kind='branch' and branch_task_id=task_id and person_task_id is null) or(kind='person' and person_task_id=task_id and branch_task_id is null))
);
create index task_tracking_completed_branch on task_tracking_private.completions(branch_task_id);
create index task_tracking_completed_person_task on task_tracking_private.completions(person_task_id);
create index task_tracking_completed_person on task_tracking_private.completions(person_id);
create index task_tracking_completed_shift on task_tracking_private.completions(shift_id);
alter table task_tracking_private.settings enable row level security;
alter table task_tracking_private.views enable row level security;
alter table task_tracking_private.completions enable row level security;
create policy no_clients on task_tracking_private.settings for all to anon,authenticated using(false) with check(false);
create policy no_clients on task_tracking_private.views for all to anon,authenticated using(false) with check(false);
create policy no_clients on task_tracking_private.completions for all to anon,authenticated using(false) with check(false);
revoke all on all tables in schema task_tracking_private from public,anon,authenticated;

create function task_tracking_private.actor(p_shift bigint,p_branch bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.staff_accounts;person text;sh public.sales_shifts;
begin
 select * into a from public.staff_accounts where user_id=auth.uid() and active;
 if not found then raise sqlstate 'PT403' using message='Войдите в свой аккаунт';end if;
 select * into sh from public.sales_shifts where id=p_shift and status='open';
 if not found or(p_branch is not null and sh.branch_id<>p_branch) then raise exception 'Откройте смену этого филиала';end if;
 if a.role<>'admin' and not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id where se.shift_id=sh.id and e.person_id=a.person_id) then raise sqlstate 'PT403' using message='Подключитесь к смене из своего аккаунта';end if;
 select name into person from public.sales_people where id=a.person_id;
 return jsonb_build_object('user_id',a.user_id,'person_id',a.person_id,'name',coalesce(person,a.name,a.login),'admin',a.role='admin');
end $$;
create function task_tracking_private.record_view(p_kind text,p_task bigint,p_shift bigint,p_actor jsonb) returns void language plpgsql security definer set search_path='' as $$
begin
 if p_actor->>'person_id' is null then return;end if;
 insert into task_tracking_private.views(kind,task_id,branch_task_id,person_task_id,person_id,actor,name,shift_id)
 values(p_kind,p_task,case when p_kind='branch' then p_task end,case when p_kind='person' then p_task end,(p_actor->>'person_id')::bigint,(p_actor->>'user_id')::uuid,p_actor->>'name',p_shift)
 on conflict(kind,task_id,person_id) do update set last_seen=now(),shift_id=excluded.shift_id;
end $$;
create function task_tracking_private.seen(p_kind text,p_task bigint,p_shift bigint) returns boolean language plpgsql security definer set search_path='' as $$
declare actor jsonb;bt public.sales_shift_tasks;pt public.sales_person_tasks;today date:=(now() at time zone 'Europe/Moscow')::date;
begin
 if not public.is_staff() then raise sqlstate 'PT403' using message='Войдите в свой аккаунт';end if;
 if p_kind='branch' then
  select * into bt from public.sales_shift_tasks where id=p_task and is_active and task_date<=today;
  if not found then return false;end if;
  actor:=task_tracking_private.actor(p_shift,bt.branch_id);
  if bt.task_date<today and bt.recurrence_id is null then return false;end if;
 elsif p_kind='person' then
  select * into pt from public.sales_person_tasks where id=p_task and is_active and completed_at is null and start_date<=today;
  if not found then return false;end if;
  actor:=task_tracking_private.actor(p_shift);
  if not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id where se.shift_id=p_shift and e.person_id=pt.person_id) then return false;end if;
 else raise exception 'Неизвестный вид задания';end if;
 -- Viewing the administrator's configuration never marks the whole staff as having seen it.
 if (actor->>'admin')::boolean then return false;end if;
 perform task_tracking_private.record_view(p_kind,p_task,p_shift,actor);return true;
end $$;
create function task_tracking_private.completed_branch() returns trigger language plpgsql security definer set search_path='' as $$
declare actor jsonb;branch bigint;
begin
 select branch_id into branch from public.sales_shift_tasks where id=new.task_id;
 actor:=task_tracking_private.actor(new.shift_id,branch);
 if tg_op='INSERT' or exists(select 1 from task_tracking_private.completions c where c.branch_completion_id=new.id) then
 insert into task_tracking_private.completions(kind,task_id,branch_task_id,branch_completion_id,actor,person_id,name,shift_id,completed_at)
 values('branch',new.task_id,new.task_id,new.id,(actor->>'user_id')::uuid,(actor->>'person_id')::bigint,actor->>'name',new.shift_id,now())
 on conflict(branch_completion_id) do nothing;
 end if;
 perform task_tracking_private.record_view('branch',new.task_id,new.shift_id,actor);return new;
end $$;
create function task_tracking_private.completed_person() returns trigger language plpgsql security definer set search_path='' as $$
declare actor jsonb;
begin
 if new.completed_at is null then return new;end if;
 if tg_op='UPDATE' and old.completed_at is not null then return new;end if;
 actor:=task_tracking_private.actor(new.completed_shift_id);
 if not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id where se.shift_id=new.completed_shift_id and e.person_id=new.person_id) then raise exception 'Сотрудник задания не участвует в смене';end if;
 insert into task_tracking_private.completions(kind,task_id,person_task_id,actor,person_id,name,shift_id,completed_at)
 values('person',new.id,new.id,(actor->>'user_id')::uuid,(actor->>'person_id')::bigint,actor->>'name',new.completed_shift_id,now());
 perform task_tracking_private.record_view('person',new.id,new.completed_shift_id,actor);return new;
end $$;
create trigger task_tracking_branch_completed after insert or update on public.sales_shift_task_completions for each row execute function task_tracking_private.completed_branch();
create trigger task_tracking_person_completed after insert or update of completed_at on public.sales_person_tasks for each row execute function task_tracking_private.completed_person();

create function task_tracking_private.details(p_kind text,p_task bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare seen jsonb;done jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('name',v.name,'person_id',v.person_id,'first_seen',v.first_seen,'last_seen',v.last_seen) order by v.first_seen),'[]') into seen from task_tracking_private.views v where v.kind=p_kind and v.task_id=p_task;
 if p_kind='branch' then
  select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(a.name,p.name,e.name,'Сотрудник'),'completed_at',coalesce(a.completed_at,c.completed_at),'shift_id',c.shift_id,'legacy',a.id is null) order by c.completed_at),'[]') into done from public.sales_shift_task_completions c left join task_tracking_private.completions a on a.branch_completion_id=c.id left join public.sales_employees e on e.id=c.completed_by_employee_id left join public.sales_people p on p.id=e.person_id where c.task_id=p_task;
 else
  select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(a.name,p.name,e.name,'Сотрудник'),'completed_at',coalesce(a.completed_at,t.completed_at),'shift_id',t.completed_shift_id,'legacy',a.id is null)),'[]') into done from public.sales_person_tasks t left join lateral(select * from task_tracking_private.completions c where c.kind='person' and c.task_id=t.id order by c.id desc limit 1)a on true left join public.sales_employees e on e.id=t.completed_by_employee_id left join public.sales_people p on p.id=e.person_id where t.id=p_task and t.completed_at is not null;
 end if;
 return jsonb_build_object('views',seen,'completions',done);
end $$;
create function task_tracking_private.list(p_data jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;total bigint;term text:=lower(trim(coalesce(p_data->>'search','')));off integer:=greatest(0,coalesce((p_data->>'offset')::integer,0));
begin
 if not public.is_admin() then raise sqlstate 'PT403' using message='Просмотры и выполнение заданий доступны администратору';end if;
 with tasks as(
  select 'branch' kind,t.id,t.title,t.task_date due_on,t.created_at,t.is_active,t.recurrence_id,b.name recipient,exists(select 1 from public.sales_shift_task_completions c where c.task_id=t.id) completed from public.sales_shift_tasks t join public.sales_branches b on b.id=t.branch_id
  union all
  select 'person',t.id,t.title,t.start_date,t.created_at,t.is_active,t.recurrence_id,p.name,t.completed_at is not null from public.sales_person_tasks t join public.sales_people p on p.id=t.person_id
 ),filtered as(select * from tasks t where(t.is_active or t.completed) and(term='' or strpos(lower(t.title||' '||t.recipient),term)>0)),page as(select * from filtered order by created_at desc,id desc,kind limit 50 offset off)
 select coalesce((select jsonb_agg(to_jsonb(x)||task_tracking_private.details(x.kind,x.id) order by x.created_at desc,x.id desc,x.kind) from page x),'[]'),(select count(*) from filtered) into rows,total;
 return jsonb_build_object('rows',rows,'total',total,'offset',off,'tracking_since',(select started_at from task_tracking_private.settings where id));
end $$;
create function public.tasks_mark_seen(p_kind text,p_task bigint,p_shift bigint) returns boolean language sql security invoker set search_path='' as $$select task_tracking_private.seen(p_kind,p_task,p_shift)$$;
create function public.tasks_tracking_list(p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select task_tracking_private.list(p_data)$$;
revoke all on all functions in schema task_tracking_private from public,anon,authenticated;
revoke all on function public.tasks_mark_seen(text,bigint,bigint),public.tasks_tracking_list(jsonb) from public,anon,authenticated;
grant execute on function task_tracking_private.seen(text,bigint,bigint),task_tracking_private.list(jsonb),public.tasks_mark_seen(text,bigint,bigint),public.tasks_tracking_list(jsonb) to authenticated;
notify pgrst,'reload schema';

do $$declare def text;begin
 def:=pg_get_functiondef('public.sales_open_team_shift(bigint,bigint[],bigint,bigint)'::regprocedure);
 def:=replace(def,'begin', $add$begin
 if not public.is_staff() then raise sqlstate 'PT403' using message='Войдите в свой аккаунт, чтобы открыть смену';end if;
 if not public.is_admin() then
  if p_person_ids[1] is distinct from (select person_id from public.staff_accounts where user_id=auth.uid() and active) then raise sqlstate 'PT403' using message='Войдите в свой аккаунт. Открыть смену на своё имя можно только под своим логином и паролем';end if;
  if exists(select 1 from unnest(p_person_ids) as ids(pid) where pid<>p_person_ids[1] and not exists(select 1 from public.sales_shifts s join public.sales_shift_employees se on se.shift_id=s.id join public.sales_employees e on e.id=se.employee_id where s.branch_id=p_branch_id and s.status='open' and e.person_id=pid)) then raise sqlstate 'PT403' using message='Каждый сотрудник подключается к смене из своего аккаунта';end if;
 end if;
$add$);
 execute def;
 def:=pg_get_functiondef('public.sales_open_or_join_shift(bigint,bigint)'::regprocedure);
 def:=replace(def,'begin', $add$begin
 if not public.is_staff() or (not public.is_admin() and not exists(select 1 from public.sales_employees e join public.staff_accounts a on a.person_id=e.person_id where e.id=p_employee_id and a.user_id=auth.uid() and a.active)) then raise sqlstate 'PT403' using message='Войдите в свой аккаунт. Открыть смену на своё имя можно только под своим логином и паролем';end if;
$add$);
 execute def;
end $$;
create table payroll_private.unlocks(user_id uuid not null,session_id uuid not null,expires_at timestamptz not null,primary key(user_id,session_id));
alter table payroll_private.unlocks enable row level security;
revoke all on payroll_private.unlocks from public,anon,authenticated;
create function public.payroll_unlock(p_user uuid,p_session uuid) returns boolean language plpgsql security definer set search_path='' as $$begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 if not exists(select 1 from auth.sessions where id=p_session and user_id=p_user) then raise exception 'Войдите в аккаунт заново';end if;
 insert into payroll_private.unlocks values(p_user,p_session,now()+interval '15 minutes') on conflict(user_id,session_id) do update set expires_at=excluded.expires_at;return true;
end $$;
revoke all on function public.payroll_unlock(uuid,uuid) from public,anon,authenticated;
grant execute on function public.payroll_unlock(uuid,uuid) to service_role;
do $$declare def text;begin
 def:=pg_get_functiondef('payroll_private.report(date,date)'::regprocedure);
 def:=replace(def,'begin', $add$begin
 if not public.is_admin() and not exists(select 1 from payroll_private.unlocks u join auth.sessions s on s.id=u.session_id and s.user_id=u.user_id where u.user_id=auth.uid() and u.session_id=(auth.jwt()->>'session_id')::uuid and u.expires_at>now()) then raise sqlstate 'PT401' using message='Введите пароль своего аккаунта, чтобы посмотреть зарплату';end if;
$add$);
 execute def;
end $$;
notify pgrst,'reload schema';

create function payroll_private.lock_salary() returns boolean language plpgsql security definer set search_path='' as $$begin delete from payroll_private.unlocks where user_id=auth.uid() and session_id=(auth.jwt()->>'session_id')::uuid;return true;end $$;
create function public.payroll_lock() returns boolean language sql security invoker set search_path='' as $$select payroll_private.lock_salary()$$;
revoke all on function payroll_private.lock_salary(),public.payroll_lock() from public,anon;
grant execute on function payroll_private.lock_salary(),public.payroll_lock() to authenticated;

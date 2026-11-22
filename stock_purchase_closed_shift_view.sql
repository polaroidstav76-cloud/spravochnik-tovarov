-- Keep pending branch requests visible after the shift closes, using the employee's latest verified shift.
create or replace function purchase_private.allowed_branches(p_shift_id bigint default null) returns bigint[]
language sql stable security definer set search_path='' as $$
 with own as (
  select distinct s.id,s.branch_id,s.status,s.ended_at,s.started_at from public.staff_accounts a
  join public.sales_employees e on e.person_id=a.person_id
  join public.sales_shift_employees se on se.employee_id=e.id
  join public.sales_shifts s on s.id=se.shift_id
  where a.user_id=auth.uid() and a.active
 ),eligible as (
  select * from own where case when exists(select 1 from own where status='open' and ended_at is null)
   then status='open' and ended_at is null
   else id=(select id from own order by started_at desc,id desc limit 1) end
 )
 select coalesce(array_agg(distinct branch_id),'{}'::bigint[]) from eligible where p_shift_id is null or id=p_shift_id
$$;
do $$declare def text;begin
 def:=pg_get_functiondef('purchase_private.branch_view(bigint)'::regprocedure);
 def:=replace(def,'if p_shift_id is null or bid is null then','if bid is null then');
 def:=replace(def,'live:=jsonb_build_object(''requests'',requested,''at'',now());','live:=jsonb_build_object(''requests'',requested,''at'',now(),''branch_id'',bid);');
 execute def;
end $$;
notify pgrst,'reload schema';

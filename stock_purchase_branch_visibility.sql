-- Employees see only their branch; admin UI/data remain unchanged.
alter table public.purchase_batches add column requested_snapshot jsonb;
create or replace function purchase_private.allowed_branches(p_shift_id bigint default null) returns bigint[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(distinct s.branch_id),'{}'::bigint[]) from public.staff_accounts a
 join public.sales_employees e on e.person_id=a.person_id
 join public.sales_shift_employees se on se.employee_id=e.id
 join public.sales_shifts s on s.id=se.shift_id
 where a.user_id=auth.uid() and a.active and s.status='open' and s.ended_at is null and (p_shift_id is null or s.id=p_shift_id)
$$;
revoke all on function purchase_private.allowed_branches(bigint) from public,anon;
grant execute on function purchase_private.allowed_branches(bigint) to authenticated;
-- Secure direct table reads as well as the UI RPC.
alter policy stock_requests_read on public.stock_requests using(public.is_admin() or (public.is_staff() and branch_id=any(purchase_private.allowed_branches())));
create or replace function public.stock_purchase_live() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_staff() then raise exception 'Требуется вход сотрудника';end if;
 return jsonb_build_object('at',now(),'rows','[]'::jsonb,'hidden','[]'::jsonb,'requests',(
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('unit',m.unit,'code',m.purchase_code,'branch_name',b.name) order by (r.status='bought'),r.urgent desc,r.created_at,r.id),'[]'::jsonb)
 from public.stock_requests r left join public.stock_materials m on m.id=r.material_id left join public.sales_branches b on b.id=r.branch_id
 where public.is_admin() or r.branch_id=any(purchase_private.allowed_branches())));
end $$;
-- Preserve the existing admin purchase workflow, Telegram formatting and idempotency.
do $$declare def text;begin
 def:=pg_get_functiondef('public.purchase_finish(uuid,jsonb,text)'::regprocedure);
 if position('existing record;' in def)=0 or position('for x in select value from jsonb_array_elements(p_lines) loop' in def)=0 then raise exception 'Unexpected purchase_finish implementation';end if;
 def:=replace(def,'existing record;','existing record; requested_before jsonb;');
 def:=replace(def,'for x in select value from jsonb_array_elements(p_lines) loop', $add$
 select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]'::jsonb) into requested_before from public.stock_requests r where r.status<>'bought';
 for x in select value from jsonb_array_elements(p_lines) loop
$add$);
 def:=replace(def,'''qty'',v_qty))','''qty'',v_qty,''branch_id'',case when x->>''request_id'' is not null then req.branch_id else (x->>''branch_id'')::bigint end,''request_id'',x->>''request_id''))');
 def:=replace(def,'values(p_id,auth.uid(),result,p_notes,msg,ids);','values(p_id,auth.uid(),result,p_notes,msg,ids); update public.purchase_batches set requested_snapshot=requested_before where id=p_id;');
 execute def;
end $$;
create or replace function purchase_private.branch_view(p_shift_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare branches bigint[];bid bigint;live jsonb;b public.purchase_batches%rowtype;requested jsonb;ordered jsonb;bn text;
begin
 if auth.uid() is null or not public.is_staff() or public.is_admin() then raise sqlstate 'PT403' using message='Требуется вход сотрудника';end if;
 branches:=purchase_private.allowed_branches(p_shift_id);bid:=branches[1];
 if p_shift_id is null or bid is null then return jsonb_build_object('requests','[]'::jsonb,'last_batch',null);end if;
 live:=public.stock_purchase_live();
 select coalesce(jsonb_agg(x),'[]'::jsonb) into requested from jsonb_array_elements(live->'requests')x where (x->>'branch_id')::bigint=bid;
 live:=jsonb_build_object('requests',requested,'at',now());
 select * into b from public.purchase_batches order by created_at desc,id desc limit 1;
 if not found then return live||jsonb_build_object('last_batch',null);end if;
 select name into bn from public.sales_branches where id=bid;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into requested from jsonb_array_elements(coalesce(b.requested_snapshot,'[]'::jsonb))x where (x->>'branch_id')::bigint=bid;
 -- Older batches only stored branch names; filter by exact existing name for those records.
 select coalesce(jsonb_agg(x),'[]'::jsonb) into ordered from jsonb_array_elements(b.lines)x where case when x->>'branch_id' is not null then (x->>'branch_id')::bigint=bid else x->>'branch'=bn end;
 return live||jsonb_build_object('last_batch',jsonb_build_object('id',b.id,'created_at',b.created_at,'snapshot_available',b.requested_snapshot is not null,'requested',requested,'ordered',ordered));
end $$;
create or replace function public.purchase_branch_view(p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$select purchase_private.branch_view(p_shift_id)$$;
revoke all on function purchase_private.branch_view(bigint),public.purchase_branch_view(bigint) from public,anon;
grant execute on function purchase_private.branch_view(bigint),public.purchase_branch_view(bigint) to authenticated;
-- Prevent a guessed request ID from deleting another branch's request.
do $$declare def text;begin
 def:=pg_get_functiondef('purchase_private.delete_request(bigint,text,numeric)'::regprocedure);
 def:=replace(def,'if not found then return false;end if;', $add$if not found then return false;end if;
 if not public.is_admin() and not coalesce(target.branch_id=any(purchase_private.allowed_branches()),false) then raise sqlstate 'PT403' using message='Можно удалить только заявку своего филиала';end if;$add$);
 execute def;
end $$;
notify pgrst,'reload schema';

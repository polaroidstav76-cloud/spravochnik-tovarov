create or replace function purchase_private.branch_view(p_shift_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare branches bigint[];bid bigint;bn text;b public.purchase_batches%rowtype;requested jsonb;ordered jsonb;live jsonb;history jsonb:='[]';item jsonb;
begin
 if auth.uid() is null or not public.is_staff() or public.is_admin() then raise sqlstate 'PT403' using message='Требуется вход сотрудника';end if;
 branches:=purchase_private.allowed_branches(p_shift_id);bid:=branches[1];
 if bid is null then return jsonb_build_object('requests','[]'::jsonb,'batches','[]'::jsonb,'last_batch',null);end if;
 select name into bn from public.sales_branches where id=bid;
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('unit',m.unit,'code',m.purchase_code,'branch_name',bn) order by r.urgent desc,r.created_at,r.id),'[]'::jsonb) into requested from public.stock_requests r left join public.stock_materials m on m.id=r.material_id where r.branch_id=bid and r.status<>'bought';
 live:=jsonb_build_object('requests',requested,'at',now(),'branch_id',bid);
 for b in select * from public.purchase_batches where created_at>=(date_trunc('month',now() at time zone 'Europe/Moscow') at time zone 'Europe/Moscow') and created_at<((date_trunc('month',now() at time zone 'Europe/Moscow')+interval '1 month') at time zone 'Europe/Moscow') order by created_at desc,id desc loop
  select coalesce(jsonb_agg(x),'[]'::jsonb) into requested from jsonb_array_elements(coalesce(b.requested_snapshot,'[]'::jsonb))x where (x->>'branch_id')::bigint=bid;
  select coalesce(jsonb_agg(x),'[]'::jsonb) into ordered from jsonb_array_elements(b.lines)x where case when x->>'branch_id' is not null then (x->>'branch_id')::bigint=bid else x->>'branch'=bn end;
  if jsonb_array_length(requested)>0 or jsonb_array_length(ordered)>0 then
   item:=jsonb_build_object('id',b.id,'created_at',b.created_at,'snapshot_available',b.requested_snapshot is not null,'requested',requested,'ordered',ordered);history:=history||jsonb_build_array(item);
  end if;
 end loop;
 return live||jsonb_build_object('batches',history,'last_batch',history->0);
end $$;
notify pgrst,'reload schema';

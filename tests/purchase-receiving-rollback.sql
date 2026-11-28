begin;
set local lock_timeout='5s';
do $$
declare actor uuid;bid bigint;mat bigint;req bigint;batch uuid:=gen_random_uuid();sheet bigint;d date:=(now() at time zone 'Europe/Moscow')::date;serial integer;payload jsonb;result jsonb;line uuid;blocked boolean;
begin
 select user_id into actor from public.staff_accounts where role='admin' and active limit 1;perform set_config('request.jwt.claim.sub',actor::text,true);
 insert into sales_branches(name,is_test) values('__purchase_receiving_rollback__',false) returning id into bid;
 serial:=d-date '1899-12-30';
 insert into report_sheets(title,branch_id,data,months) values('__purchase_receiving_rollback__',bid,jsonb_build_object('ncols',19,'rows',jsonb_build_object('1',jsonb_build_object('A',jsonb_build_object('v','Месяц')),'2',jsonb_build_object('O',jsonb_build_object('v','Расходы'),'P',jsonb_build_object('v','Комментарий')),'3',jsonb_build_object('A',jsonb_build_object('v',serial),'O',jsonb_build_object('v',25),'P',jsonb_build_object('v','Ручной расход')),'5',jsonb_build_object('A',jsonb_build_object('v','Итого')))),jsonb_build_array(jsonb_build_object('m',to_char(d,'YYYY-MM'),'from',1,'to',5))) returning id into sheet;
 insert into stock_materials(name,unit,pack_qty) values('__purchase_receiving_rollback__','лист',500) returning id into mat;
 insert into stock_requests(name,branch_id,material_id,qty) values('__purchase_receiving_rollback__',bid,mat,10) returning id into req;
 payload:=jsonb_build_array(jsonb_build_object('request_id',req,'qty',2,'unit_price',100,'purchase_receiving',1));
 result:=public.purchase_finish(batch,payload,null);assert(result->>'received')::boolean;
 assert(select sum(qty) from stock_moves where group_id=batch)=1000;
 assert(select status from stock_requests where id=req)='bought';
 assert(select(data->'rows'->'3'->'T'->>'v')::numeric from report_sheets where id=sheet)=200;
 assert(select(data->'rows'->'3'->'O'->>'v')::numeric from report_sheets where id=sheet)=25;
 perform public.purchase_finish(batch,payload,null);assert(select count(*) from stock_moves where group_id=batch)=1;
 select id into line from purchase_private.received_lines where batch_id=batch;
 perform public.purchase_set_price(line,null,1);assert(select qty from stock_moves where purchase_line_id=line)=1000;
 perform public.purchase_set_price(line,0,2);assert(select(data->'rows'->'3'->'T'->>'v')::numeric from report_sheets where id=sheet)=0;
 blocked:=false;begin update report_sheets set data=jsonb_set(data,'{rows,3,T,v}','999') where id=sheet;exception when others then blocked:=true;end;assert blocked;
 assert not has_table_privilege('authenticated','purchase_private.received_lines','select');
end $$;
rollback;

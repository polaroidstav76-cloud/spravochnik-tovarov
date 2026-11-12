begin;
do $test$
declare actor uuid; sh bigint; emp bigint; bid bigint; oid bigint; original public.pickup_orders%rowtype; changed public.pickup_orders%rowtype;
 cat bigint; returned bigint; sales_before bigint; counters_before jsonb; pending_before bigint; mat bigint; n integer; denied boolean:=false;
 nm text:='__codex_receipt_20261112_'||gen_random_uuid()::text;
begin
 select user_id into actor from public.staff_accounts where active and role='admin' limit 1;
 if actor is null then raise exception 'No authorised test actor'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 select s.id,se.employee_id,s.branch_id into sh,emp,bid from public.sales_shifts s join public.sales_shift_employees se on se.shift_id=s.id where s.status='open' order by s.id desc limit 1;
 if sh is null then raise exception 'No open shift for rollback test'; end if;
 select id into cat from public.sales_catalog where is_active=true order by id limit 1;
 select * into original from public.pickup_orders where status='pending' order by id desc limit 1;
 if original.id is null then raise exception 'No pending order for rollback test'; end if;
 select count(*) into sales_before from public.sales;
 select count(*) into pending_before from public.pickup_orders;
 select jsonb_agg(to_jsonb(c) order by branch_id) into counters_before from public.sales_branch_order_counters c;
 returned:=public.sales_update_pickup(original.id,sh,emp,jsonb_build_array(jsonb_build_object('catalog_id',cat,'quantity',2,'unit_price',20),jsonb_build_object('catalog_id',cat,'quantity',1,'unit_price',40)),10,'__rollback_test',original.customer_id,original.client_name,original.client_phone,original.client_order_ref);
 select * into changed from public.pickup_orders where id=original.id;
 if returned is distinct from original.order_number or changed.total<>72 or jsonb_array_length(changed.items)<>2 or changed.status<>'pending' or changed.branch_id<>original.branch_id or changed.created_at<>original.created_at or changed.remind1_at is distinct from original.remind1_at then raise exception 'Order amendment failed'; end if;
 if (select count(*) from public.sales)<>sales_before or (select count(*) from public.pickup_orders)<>pending_before or (select jsonb_agg(to_jsonb(c) order by branch_id) from public.sales_branch_order_counters c) is distinct from counters_before then raise exception 'Amendment created a sale, duplicate or new number'; end if;
 n:=public.stock_operation(sh,null,'receipt',bid,jsonb_build_array(jsonb_build_object('name',nm,'qty',3,'price_total',75)));
 select id into mat from public.stock_materials where name=nm;
 if n<>1 or mat is null or (select sum(qty) from public.stock_moves where material_id=mat and branch_id=bid)<>3 then raise exception 'Free receipt failed'; end if;
 perform public.stock_operation(sh,null,'receipt',bid,jsonb_build_array(jsonb_build_object('name',upper(nm),'qty',2)));
 if (select count(*) from public.stock_materials where lower(name)=lower(nm))<>1 or (select sum(qty) from public.stock_moves where material_id=mat and branch_id=bid)<>5 then raise exception 'Repeated receipt created duplicate'; end if;
 begin
   perform public.stock_operation(sh,null,'receipt',bid,jsonb_build_array(jsonb_build_object('name',nm||'_invalid','qty',1),jsonb_build_object('name',nm||'_invalid2','qty',0)));
   raise exception 'Expected validation error';
 exception when others then
   if SQLERRM='Expected validation error' then raise; end if;
 end;
 if exists(select 1 from public.stock_materials where name=nm||'_invalid') then raise exception 'Failed receipt left orphan material'; end if;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.sales_update_pickup(original.id,sh,emp,'[]'); exception when others then denied:=SQLERRM='Требуется вход сотрудника'; end;
 if not denied then raise exception 'Anonymous amendment accepted'; end if;
 denied:=false;
 begin perform public.stock_operation(sh,null,'receipt',bid,'[]'); exception when others then denied:=SQLERRM='Требуется вход сотрудника'; end;
 if not denied then raise exception 'Anonymous receipt accepted'; end if;
end $test$;
rollback;
select 'PASS: same pending order and number, updated totals, no revenue or duplicates; free receipt and name reuse; atomic validation rollback; unauthenticated access denied. All test writes rolled back.' result;

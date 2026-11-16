do $test$
declare actor uuid; bid bigint;person bigint;emp bigint;sh bigint;oldsh bigint;sheet bigint;template public.report_sheets;ctx record;mov1 bigint;mov2 bigint;mat bigint;preview jsonb;amount numeric;note text;nm text:='__workflow_'||replace(gen_random_uuid()::text,'-','');n1 text;n2 text;c1 uuid;c2 uuid;out_id uuid;cat bigint;sale_order bigint;creator text;failed boolean;pick bigint;
begin
 select user_id into actor from public.staff_accounts where active and role='admin' limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 select * into template from public.report_sheets r where branch_id is not null and exists(select 1 from jsonb_array_elements(r.months) m where m->>'m'=to_char(now() at time zone 'Europe/Moscow','YYYY-MM')) order by id limit 1;
 if template.id is null then raise exception 'Missing report template';end if;
 insert into public.sales_branches(name,is_test,is_workshop) values(nm,false,false) returning id into bid;
 insert into public.sales_people(name) values(nm) returning id into person;
 insert into public.sales_employees(branch_id,name,person_id) values(bid,nm,person) returning id into emp;
 insert into public.sales_shifts(branch_id,employee_id,status) values(bid,emp,'open') returning id into sh;
 insert into public.sales_shift_employees(shift_id,employee_id) values(sh,emp);
 sheet:=-1000000-floor(random()*1000000000)::bigint;
 insert into public.report_sheets(id,title,branch_id,data,months) values(sheet,nm||' Выручка',bid,template.data,template.months);
 select * into ctx from public.report_day_row(bid,(now() at time zone 'Europe/Moscow')::date);
 perform public.report_put_row(sheet,ctx.row_no,jsonb_build_object('O',100,'P','Ручной расход: доставка'));
 insert into public.stock_materials(name,unit) values(nm,'шт') returning id into mat;
 insert into public.stock_moves(material_id,branch_id,qty,kind,price_total,person_id,person_name,shift_id) values(mat,bid,1,'receipt',35,person,nm,sh) returning id into mov1;
 select (data->'rows'->ctx.row_no::text->'O'->>'v')::numeric,data->'rows'->ctx.row_no::text->'P'->>'v' into amount,note from public.report_sheets where id=sheet;
 if amount<>135 or note not like '%Ручной расход%' or note not like '%'||nm||'%' then raise exception 'Receipt did not add to expense while preserving manual note: %',amount;end if;
 insert into public.stock_moves(material_id,branch_id,qty,kind,price_total,person_id,person_name,shift_id) values(mat,bid,2,'receipt',20,person,nm,sh) returning id into mov2;
 perform workflow_private.sync_expenses(bid,(now() at time zone 'Europe/Moscow')::date);
 select (data->'rows'->ctx.row_no::text->'O'->>'v')::numeric into amount from public.report_sheets where id=sheet;
 if amount<>155 then raise exception 'Receipt duplicate accounting: %',amount;end if;
 update public.stock_moves set cancelled_at=now() where id=mov1;
 select (data->'rows'->ctx.row_no::text->'O'->>'v')::numeric into amount from public.report_sheets where id=sheet;
 if amount<>120 then raise exception 'Cancelled receipt did not reverse expense: %',amount;end if;
 perform public.report_fill_shift(sh,'auto');
 perform public.report_staff_set(sh,'O','140'::jsonb);
 perform public.report_staff_set(sh,'P','"Добавили ручной расход"'::jsonb);
 insert into public.stock_moves(material_id,branch_id,qty,kind,price_total,person_id,person_name,shift_id) values(mat,bid,1,'receipt',5,person,nm,sh);
 select (data->'rows'->ctx.row_no::text->'O'->>'v')::numeric,data->'rows'->ctx.row_no::text->'P'->>'v' into amount,note from public.report_sheets where id=sheet;
 if amount<>145 or note not like '%Добавили ручной расход%' then raise exception 'Manual expense was lost: %',amount;end if;
 begin perform public.report_staff_set(sh,'O','1'::jsonb);raise exception 'FAIL: erased automatic receipt expense';exception when others then if sqlerrm like 'FAIL:%' then raise;end if;end;
 -- Historic amounts are reviewed; adding twice is idempotent.
 insert into public.sales_shifts(branch_id,employee_id,status,started_at,ended_at) values(bid,emp,'closed',now()-interval '1 day',now()-interval '23 hours') returning id into oldsh;
 select * into ctx from public.report_day_row(bid,((now()-interval '1 day') at time zone 'Europe/Moscow')::date);
 perform public.report_put_row(sheet,ctx.row_no,jsonb_build_object('O',50,'P','Старый комментарий'));
 insert into public.stock_moves(material_id,branch_id,qty,kind,price_total,person_id,person_name,shift_id,created_at) values(mat,bid,1,'receipt',20,person,nm,oldsh,now()-interval '1 day');
 preview:=workflow_private.expense_preview(bid,((now()-interval '1 day') at time zone 'Europe/Moscow')::date);
 if (preview->>'report_total')::numeric<>50 or (preview->>'synced_total')::numeric<>0 then raise exception 'Historical expense was silently doubled';end if;
 preview:=public.workflow_reconcile_expenses(bid,((now()-interval '1 day') at time zone 'Europe/Moscow')::date,'already_included',50,20);
 if (preview->>'report_total')::numeric<>50 then raise exception 'Historical include reconciliation changed total';end if;
 preview:=public.workflow_reconcile_expenses(bid,((now()-interval '1 day') at time zone 'Europe/Moscow')::date,'add_receipts',50,20);
 if (preview->>'report_total')::numeric<>50 then raise exception 'Repeated reconciliation doubled a receipt';end if;
 -- Phone variants cannot create or rename a second card.
 loop
  n1:='7900'||lpad((floor(random()*10000000)::bigint)::text,7,'0');n2:='7911'||right(n1,7);
  exit when not exists(select 1 from public.loyalty_customers where public.loyalty_normalize_phone(phone) in(n1,n2));
 end loop;
 perform set_config('workflow.creator_person','',true);
 select customer_id into c1 from public.loyalty_register_customer(nm,n1,null,person);
 select customer_id into out_id from public.loyalty_register_customer('Must not rename','8'||right(n1,10),null,null);
 if out_id<>c1 or (select name from public.loyalty_customers where id=c1)<>nm then raise exception 'Repeat registration changed identity';end if;
 begin insert into public.loyalty_customers(name,phone) values(nm||'_duplicate',right(n1,10));raise exception 'FAIL: duplicate normalized phone accepted';exception when others then if sqlerrm like 'FAIL:%' then raise;end if;end;
 select customer_id into c2 from public.loyalty_register_customer(nm||'_second',n2,null,person);
 if (select count(*) from public.loyalty_find_customers(right(n1,4)) where customer_id in(c1,c2))<>2 then raise exception 'Suffix lookup lost matching clients';end if;
 if (select count(*) from public.loyalty_find_customers('778'||right(n1,10)) where customer_id=c1)<>1 then raise exception 'Legacy prefix lookup failed';end if;
 if (public.workflow_card_creator(c1)->>'name')<>nm then raise exception 'Creator missing';end if;
 insert into public.loyalty_transactions(customer_id,transaction_type,points,available_at) values(c1,'adjustment',20,now()),(c1,'adjustment',50,now()+interval '1 day');
 begin perform public.loyalty_redeem(c1,100,30,'rollback');raise exception 'FAIL: spent more than client balance';exception when others then if sqlerrm like 'FAIL:%' then raise;end if;end;
 if public.loyalty_redeem(c1,100,20,'rollback')<>0 then raise exception 'Balance-limited redemption failed';end if;
 -- New card via a normal sale records the selected cashier.
 select id into cat from public.sales_catalog where is_active order by id limit 1;
 loop n2:='7922'||lpad((floor(random()*10000000)::bigint)::text,7,'0');exit when not exists(select 1 from public.loyalty_customers where public.loyalty_normalize_phone(phone)=n2);end loop;
 sale_order:=public.sales_create_sale(sh,emp,'cash',nm,jsonb_build_array(jsonb_build_object('catalog_id',cat,'quantity',1,'unit_price',100)),null,0,nm||'_sale',n2,null,null,0,'[]');
 if not exists(select 1 from public.loyalty_customers where phone=n2 and created_by_employee_id=person) then raise exception 'Sale-created card has no author';end if;
 -- A new pickup can be cancelled immediately, without becoming overdue.
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(bid,sh,emp,999999,'[]',100,100,'pending') returning id into pick;
 perform public.sales_cancel_pickup(pick,'Ошибка при оформлении');
 if (select status from public.pickup_orders where id=pick)<>'cancelled' then raise exception 'Fresh pickup cancellation failed';end if;
 if has_function_privilege('anon','public.workflow_card_stats(date,date)','execute') or has_function_privilege('authenticated','workflow_private.sync_expenses(bigint,date)','execute') then raise exception 'Excessive workflow grants';end if;
end $test$;

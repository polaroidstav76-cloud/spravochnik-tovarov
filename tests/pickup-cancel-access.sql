-- Execute inside BEGIN/ROLLBACK; fixtures never survive the test.
do $test$
declare owner_user uuid;other_user uuid;admin_user uuid;owner_person bigint;other_person bigint;
 b bigint;b2 bigint;e bigint;e2 bigint;sh bigint;sh2 bigint;p bigint;ok boolean;blocked boolean;
begin
 select user_id,person_id into owner_user,owner_person from public.staff_accounts where active and role='staff' and person_id is not null order by user_id limit 1;
 select user_id,person_id into other_user,other_person from public.staff_accounts where active and role='staff' and person_id<>owner_person order by user_id limit 1;
 select user_id into admin_user from public.staff_accounts where active and role='admin' limit 1;
 if owner_user is null or other_user is null or admin_user is null then raise exception 'Missing test actors';end if;
 insert into public.sales_branches(name,is_test) values('__pickup_access_'||gen_random_uuid(),true) returning id into b;
 insert into public.sales_branches(name,is_test) values('__pickup_other_'||gen_random_uuid(),true) returning id into b2;
 insert into public.sales_employees(branch_id,name,person_id) values(b,'Test owner',owner_person) returning id into e;
 insert into public.sales_employees(branch_id,name,person_id) values(b,'Test other',other_person) returning id into e2;
 insert into public.sales_shifts(branch_id,employee_id,status,ended_at) values(b,e,'closed',now()) returning id into sh;
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(b,sh,e,999999,'[]',100,100,'pending') returning id into p;
 -- Creator of a just-created pending order can cancel after shift closure, as authenticated staff.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_user,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 ok:=public.sales_cancel_pickup(p,'Test creator closed shift');
 execute 'reset role';
 if not ok or not exists(select 1 from public.pickup_orders where id=p and status='cancelled' and cancelled_at is not null and cancel_reason='Test creator closed shift') then raise exception 'Creator cancellation failed';end if;
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(b,sh,e,999999,'[]',100,100,'pending') returning id into p;
 -- A different employee merely assigned to this branch does not gain cancellation access.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',other_user,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.sales_cancel_pickup(p,'Forbidden');exception when sqlstate 'PT403' then blocked:=true;end;
 execute 'reset role';
 if not blocked then raise exception 'Unrelated staff gained access';end if;
 -- Open shift in another branch is insufficient.
 insert into public.sales_shifts(branch_id,employee_id,status) values(b2,e2,'open') returning id into sh2;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',other_user,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.sales_cancel_pickup(p,'Forbidden other branch');exception when sqlstate 'PT403' then blocked:=true;end;
 execute 'reset role';
 if not blocked then raise exception 'Cross-branch cancellation allowed';end if;
 update public.sales_shifts set status='closed',ended_at=now() where id=sh2;
 -- Primary cashier of target branch's open shift works even without a participant row.
 insert into public.sales_shifts(branch_id,employee_id,status) values(b,e2,'open') returning id into sh2;
 execute 'set local role authenticated';
 ok:=public.sales_cancel_pickup(p,'Test primary cashier');
 execute 'reset role';
 if not ok then raise exception 'Primary cashier denied';end if;
 -- Joined secondary cashier also works.
 update public.sales_shifts set employee_id=e where id=sh2;
 insert into public.sales_shift_employees(shift_id,employee_id) values(sh2,e2);
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(b,sh,e,999999,'[]',100,100,'pending') returning id into p;
 execute 'set local role authenticated';ok:=public.sales_cancel_pickup(p,'Test secondary cashier');execute 'reset role';
 if not ok then raise exception 'Secondary cashier denied';end if;
 -- Administrator can cancel without belonging to any shift; blank reason remains forbidden.
 insert into public.pickup_orders(branch_id,shift_id,employee_id,order_number,items,gross_total,total,status) values(b,sh,e,999999,'[]',100,100,'pending') returning id into p;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_user,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.sales_cancel_pickup(p,'  ');exception when others then blocked:=sqlerrm='Укажите причину удаления';end;
 if not blocked then raise exception 'Blank reason accepted';end if;
 ok:=public.sales_cancel_pickup(p,'Test administrator');
 blocked:=false;begin perform public.sales_cancel_pickup(p,'Again');exception when others then blocked:=sqlerrm='Заказ не найден или уже закрыт';end;
 execute 'reset role';
 if not ok or not blocked then raise exception 'Administrator or closed-order guard failed';end if;
 if has_function_privilege('anon','public.sales_cancel_pickup(bigint,text)','execute') then raise exception 'Anonymous access granted';end if;
end $test$;

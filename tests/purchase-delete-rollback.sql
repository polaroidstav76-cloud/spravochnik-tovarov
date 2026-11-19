do $$
declare staff uuid;admin uuid;rid bigint;before_moves bigint;blocked boolean;
begin
 select user_id into staff from public.staff_accounts where active and role='staff' limit 1;
 select user_id into admin from public.staff_accounts where active and role='admin' limit 1;
 select count(*) into before_moves from public.stock_moves;
 insert into public.stock_requests(name,qty,ordered_qty,status,urgent) values('__delete_test_staff',5,2,'open',true) returning id into rid;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.stock_request_delete(rid,'open',0);exception when sqlstate 'PT409' then blocked:=true;end;
 if not blocked then raise exception 'Stale purchase request deleted';end if;
 if not public.stock_request_delete(rid,'open',2) then raise exception 'Staff deletion failed';end if;
 if public.stock_request_delete(rid,'open',2) then raise exception 'Repeat deletion not idempotent';end if;
 execute 'reset role';
 if exists(select 1 from public.stock_requests where id=rid) then raise exception 'Request still visible';end if;
 if not exists(select 1 from purchase_private.deleted_requests where request_id=rid and deleted_by=staff and (request_snapshot->>'ordered_qty')::numeric=2) then raise exception 'Deletion audit missing';end if;
 insert into public.stock_requests(name,qty,ordered_qty,status) values('__delete_test_admin',1,1,'bought') returning id into rid;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 if not public.stock_request_delete(rid,'bought',1) then raise exception 'Admin deletion failed';end if;
 execute 'reset role';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
 execute 'set local role authenticated';
 blocked:=false;begin perform public.stock_request_delete(rid,'bought',1);exception when sqlstate 'PT403' then blocked:=true;end;
 execute 'reset role';if not blocked then raise exception 'Nonstaff account allowed';end if;
 if (select count(*) from public.stock_moves)<>before_moves then raise exception 'Stock moves affected';end if;
 if has_function_privilege('anon','public.stock_request_delete(bigint,text,numeric)','execute') or has_table_privilege('authenticated','purchase_private.deleted_requests','select') then raise exception 'Excessive grants';end if;
end $$;

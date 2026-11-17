do $$
declare b bigint;device uuid;token text:=repeat('b',64);actor uuid;target_shift bigint;other_shift bigint;emp bigint;result jsonb;blocked boolean;
begin
 select user_id into actor from public.staff_accounts where active and role='staff' limit 1;
 select s.id into target_shift from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id where b.name='Тухачевского 26/10' and s.status='open' limit 1;
 if target_shift is null then
  select e.id into emp from public.sales_employees e join public.sales_branches b on b.id=e.branch_id where b.name='Тухачевского 26/10' limit 1;
  insert into public.sales_shifts(branch_id,employee_id,status) select branch_id,id,'open' from public.sales_employees where id=emp returning id into target_shift;
 end if;
 select s.id into other_shift from public.sales_shifts s join public.sales_branches b on b.id=s.branch_id where b.name<>'Тухачевского 26/10' limit 1;
 insert into public.sales_branches(name,is_test) values('__vpn_test_'||gen_random_uuid(),true) returning id into b;
 insert into print_private.devices(role,branch_id,token_hash,label) values('source',b,encode(sha256(convert_to(token,'UTF8')),'hex'),'VPN test') returning id into device;
 execute 'set local role service_role';
 perform public.print_vpn_publish(token,jsonb_build_object('slots',jsonb_build_array(jsonb_build_object('direction','wideformat','due_at',now()+interval '10 minutes'))));
 execute 'reset role';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 result:=public.print_vpn_reminders(target_shift);
 if jsonb_array_length(result)<>1 then raise exception 'Target branch missing reminder';end if;
 if public.print_vpn_reminders(other_shift)<>'[]'::jsonb then raise exception 'Reminder visible at other branch';end if;
 execute 'reset role';
 execute 'set local role service_role';
 perform public.print_vpn_publish(token,'{"slots":[]}');
 execute 'reset role';
 if exists(select 1 from print_private.vpn_slots where source_device=device) then raise exception 'Changed schedule did not cancel warning';end if;
 execute 'set local role service_role';
 blocked:=false;begin perform public.print_vpn_publish(repeat('a',64),'{}');exception when sqlstate 'PT401' then blocked:=true;end;
 execute 'reset role';if not blocked then raise exception 'Invalid token accepted';end if;
 if has_function_privilege('authenticated','public.print_vpn_publish(text,jsonb)','execute') or has_table_privilege('authenticated','print_private.vpn_slots','select') then raise exception 'Excessive access';end if;
end $$;

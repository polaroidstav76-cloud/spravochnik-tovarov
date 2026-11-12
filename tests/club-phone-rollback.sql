begin;
do $test$
declare actor uuid; n1 text; n2 text; n3 text; suffix text; id1 uuid; id2 uuid; id3 uuid; id4 uuid; got uuid; num integer; failed boolean:=false;
begin
 select user_id into actor from public.staff_accounts where active and role='admin' limit 1;
 if actor is null then raise exception 'No test actor'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 loop
 suffix:=lpad((floor(random()*1000)::int)::text,3,'0');
 n1:='7900'||suffix||'4321';n2:='7911'||suffix||'4321';n3:='7922'||suffix||'4321';
 exit when not exists(select 1 from public.loyalty_customers where public.loyalty_normalize_phone(phone) in(n1,n2,n3));
 end loop;
 select customer_id into id1 from public.loyalty_register_customer('__test_phone_one',n1,null,null);
 select customer_id into id2 from public.loyalty_register_customer('__test_phone_two',n2,null,null);
 select customer_id into got from public.loyalty_register_customer('__test_phone_one','8'||right(n1,10),null,null);
 if got<>id1 then raise exception 'Registration created duplicate'; end if;
 select customer_id into got from public.loyalty_register_customer('__test_phone_one',right(n1,10),null,null);
 if got<>id1 then raise exception 'National registration created duplicate'; end if;
 select count(*) into num from public.loyalty_find_customers(right(n1,4)) where customer_id in(id1,id2);
 if num<>2 then raise exception 'Suffix search failed'; end if;
 select count(*),min(customer_id::text)::uuid into num,got from public.loyalty_find_customers('+7 ('||substring(n1,2,3)||') '||substring(n1,5));
 if num<>1 or got<>id1 then raise exception 'Full formatted phone lookup failed'; end if;
 select count(*),min(customer_id::text)::uuid into num,got from public.loyalty_find_customers('8'||right(n1,10));
 if num<>1 or got<>id1 then raise exception '8-prefix lookup failed'; end if;
 select count(*),min(customer_id::text)::uuid into num,got from public.loyalty_find_customers(right(n2,10));
 if num<>1 or got<>id2 then raise exception 'National lookup selected wrong matching-suffix customer'; end if;
 begin
   perform public.loyalty_register_customer('__invalid','1234',null,null);
 exception when others then failed:=true;
 end;
 if not failed then raise exception 'Short new phone accepted'; end if;
 insert into public.loyalty_customers(name,phone) values('__legacy_one','8'||right(n3,10)) returning id into id3;
 insert into public.loyalty_customers(name,phone) values('__legacy_two',right(n3,10)) returning id into id4;
 select count(*) into num from public.loyalty_find_customers(n3);
 if num<>2 then raise exception 'Legacy duplicate lookup failed'; end if;
 if public.loyalty_phone_for_write('8'||right(n3,10),true)<>'8'||right(n3,10) then raise exception 'Selected legacy card identity lost'; end if;
 select customer_id into got from public.loyalty_add_purchase('__legacy_one','8'||right(n3,10),100,null);
 if got<>id3 then raise exception 'Purchase credited wrong legacy card'; end if;
 select customer_id into got from public.loyalty_add_purchase('__legacy_two',right(n3,10),100,null);
 if got<>id4 then raise exception 'Purchase credited wrong second legacy card'; end if;
 failed:=false;
 begin perform public.loyalty_register_customer('__ambiguous',n3,null,null); exception when others then failed:=true; end;
 if not failed then raise exception 'Ambiguous registration was silently selected'; end if;
end $test$;
rollback;
select 'PASS: prefix variants reuse same card; full-number search separates matching last-four numbers; invalid short creation rejected; legacy duplicate cards remain separate and purchases credit selected IDs. Test data rolled back.' result;

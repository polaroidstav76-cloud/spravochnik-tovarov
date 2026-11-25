begin;
do $$
declare actor uuid;branch bigint:=-9026112501;person bigint:=-9026112501;catalog bigint:=-9026112501;card uuid;order_no bigint;test_sale bigint;q jsonb;rows jsonb;ack jsonb;rule bigint;note bigint;detail jsonb;failed boolean;old_total numeric;
begin
 select user_id into actor from public.staff_accounts where active and role='admin' limit 1;
 if actor is null then raise exception 'Test needs an existing admin';end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 insert into public.sales_branches(id,name) values(branch,'__rollback_commerce_test__');
 insert into public.sales_people(id,name) values(person,'__rollback_commerce_test__');
 insert into public.sales_employees(id,branch_id,person_id,name) values(person,branch,person,'__rollback_commerce_test__');
 insert into public.sales_shifts(id,branch_id,employee_id) values(branch,branch,person);
 insert into public.sales_shift_employees(shift_id,employee_id) values(branch,person);
 insert into public.sales_catalog(id,name,item_type,price,wholesale_prices) values(catalog,'__rollback_commerce_test__','product',100,'[{"min_qty":10,"price":95}]');
 insert into public.loyalty_customers(name,phone) values('__rollback_commerce_test__','7999'||lpad((floor(random()*10000000)::bigint)::text,7,'0')) returning id into card;
 insert into commerce_private.promos(code,title,kind,value,starts_at,ends_at) values('__ROLLBACK_'||upper(replace(gen_random_uuid()::text,'-','')),'Test','percent',10,now()-interval '1 day',now()+interval '1 day') returning id into rule;
 insert into commerce_private.notices(catalog_id,min_qty,kind,message) values(catalog,10,'message','__rollback_notice__') returning id into note;
 rows:=jsonb_build_array(jsonb_build_object('catalog_id',catalog,'quantity',10,'unit_price',95));
 q:=public.commerce_quote((select code from commerce_private.promos where id=rule),card,rows);
 if(q->>'total')::numeric<>900 or(q->>'normal_total')::numeric<>950 then raise exception 'Bad quote: %',q;end if;
 ack:=jsonb_build_array(jsonb_build_object('id',note,'version',1));
 rows:=jsonb_set(q->'items','{0,_checkout}',jsonb_build_object('code',q->'code','version',q->'version','total',q->'total','ack',ack));
 order_no:=public.sales_create_sale_v6(gen_random_uuid(),null,branch,person,'cash','Rollback test',rows,p_loyalty_customer_id:=card,p_discount_percent:=10);
 select id,total into test_sale,old_total from public.sales where branch_id=branch and order_number=order_no;
 if old_total<>900 then raise exception 'Bad sale total';end if;
 failed:=false;
 begin perform public.commerce_quote(q->>'code',card,rows);exception when others then failed:=sqlerrm like '%уже использован%';end;
 if not failed then raise exception 'Second redemption was not rejected';end if;
 detail:=public.commerce_get_sale(test_sale,branch);
 rows:=jsonb_set(detail->'items','{0,quantity}','20');rows:=jsonb_set(rows,'{0,_checkout}',jsonb_build_object('ack',ack));
 perform public.commerce_edit_sale(test_sale,branch,0,rows,0,0,'card','[]','Edited rollback test');
 if(select total from public.sales where id=test_sale)<>1800 then raise exception 'Bad edited promo total';end if;
 if(select count(*) from commerce_private.redemptions where customer_id=card)<>1 then raise exception 'Redemption changed on edit';end if;

end $$;
rollback;

-- Owner Cloudshop: atomic promotion checkout, payment notices and audited sale edits.
create schema if not exists commerce_private;
revoke all on schema commerce_private from public,anon;
grant usage on schema commerce_private to authenticated;
alter table public.sales add column if not exists edit_version integer not null default 0;
create table if not exists commerce_private.sale_edits(id bigint generated always as identity primary key,sale_id bigint not null references public.sales(id),actor uuid not null,changed_at timestamptz not null default now(),kind text not null,before_state jsonb not null,after_state jsonb not null);
create index if not exists sale_edits_sale_idx on commerce_private.sale_edits(sale_id,changed_at);
alter table commerce_private.sale_edits enable row level security;
revoke all on commerce_private.sale_edits from public,anon,authenticated;
create policy no_client_access on commerce_private.sale_edits for all to anon,authenticated using(false) with check(false);
create table commerce_private.promos(
 id bigint generated always as identity primary key,
 code text not null unique check(code=upper(trim(code)) and length(code) between 1 and 64),
 title text not null check(length(title) between 1 and 200),
 kind text not null check(kind in('percent','amount','products','gift')),
 value numeric not null default 0 check(value>=0 and value<=99999999),
 product_ids bigint[] not null default '{}',
 gift_id bigint references public.sales_catalog(id),gift_qty integer not null default 1 check(gift_qty between 1 and 10000),
 retail_only boolean not null default true,
 starts_at timestamptz not null default now(),ends_at timestamptz not null,
 active boolean not null default true,version integer not null default 1,
 created_by uuid not null default auth.uid(),updated_at timestamptz not null default now(),
 check(ends_at>starts_at),check(kind not in('percent','products') or value<=100),
 check(kind<>'products' or cardinality(product_ids)>0),check(kind<>'gift' or gift_id is not null)
);
create table commerce_private.redemptions(
 id bigint generated always as identity primary key,promo_id bigint not null references commerce_private.promos(id),
 customer_id uuid not null references public.loyalty_customers(id),sale_id bigint not null unique references public.sales(id),
 rule jsonb not null,quote jsonb not null,actor uuid not null default auth.uid(),created_at timestamptz not null default now(),
 unique(promo_id,customer_id)
);
create table commerce_private.notices(
 id bigint generated always as identity primary key,catalog_id bigint not null references public.sales_catalog(id),
 min_qty numeric not null default 1 check(min_qty>0),kind text not null check(kind in('notice','message')),
 message text not null check(length(message) between 1 and 4000),active boolean not null default true,version integer not null default 1
);
create table commerce_private.acknowledgements(
 sale_id bigint primary key references public.sales(id),actor uuid not null,ack jsonb not null,created_at timestamptz not null default now()
);
alter table commerce_private.promos enable row level security;
alter table commerce_private.redemptions enable row level security;
alter table commerce_private.notices enable row level security;
alter table commerce_private.acknowledgements enable row level security;
create policy no_client_access on commerce_private.promos for all to anon,authenticated using(false) with check(false);
create policy no_client_access on commerce_private.redemptions for all to anon,authenticated using(false) with check(false);
create policy no_client_access on commerce_private.notices for all to anon,authenticated using(false) with check(false);
create policy no_client_access on commerce_private.acknowledgements for all to anon,authenticated using(false) with check(false);
revoke all on all tables in schema commerce_private from public,anon,authenticated;

create function commerce_private.notices_for(p_items jsonb) returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(n) order by n.id),'[]') from commerce_private.notices n
 where public.is_staff() and n.active and n.min_qty<=(select sum((i->>'quantity')::numeric) from jsonb_array_elements(p_items) i where (i->>'catalog_id')::bigint=n.catalog_id)
$$;
create function commerce_private.check_ack(p_items jsonb,p_ack jsonb) returns void language plpgsql security definer set search_path='' as $$
declare n jsonb;
begin
 for n in select * from jsonb_array_elements(commerce_private.notices_for(p_items)) loop
  if not coalesce(p_ack,'[]') @> jsonb_build_array(jsonb_build_object('id',n->'id','version',n->'version')) then raise exception 'Перед оплатой подтвердите предупреждение: %',n->>'message';end if;
 end loop;
end $$;

create or replace function commerce_private.actor(p_sale_id bigint,p_shift_id bigint) returns public.sales
language plpgsql security definer set search_path='' as $$
declare s public.sales;sh public.sales_shifts;
begin
 if not public.is_staff() then raise sqlstate 'PT401' using message='Требуется вход сотрудника';end if;
 select * into s from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Продажа не найдена';end if;
 if not public.is_admin() then
  select * into sh from public.sales_shifts where id=p_shift_id and status='open';
  if not found or sh.branch_id<>s.branch_id or not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id join public.staff_accounts a on a.person_id=e.person_id where se.shift_id=sh.id and a.user_id=auth.uid() and a.active) then raise exception 'Откройте смену в филиале этой продажи';end if;
 end if;
 return s;
end $$;
create or replace function commerce_private.snapshot(p_sale_id bigint) returns jsonb language sql security definer set search_path='' as $$
 select jsonb_build_object('sale',to_jsonb(s),'items',coalesce((select jsonb_agg(i order by i.id) from public.sale_items i where sale_id=s.id),'[]'),'payments',coalesce((select jsonb_agg(p order by p.id) from public.sale_payments p where sale_id=s.id),'[]'),'stock',coalesce((select jsonb_agg(sm) from public.stock_moves sm where sale_id=s.id and cancelled_at is null),'[]'),'debts',coalesce((select jsonb_agg(d) from public.customer_debts d where sale_id=s.id),'[]')) from public.sales s where id=p_sale_id
$$;
create or replace function commerce_private.get_sale(p_sale_id bigint,p_shift_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.sales;
begin
 s:=commerce_private.actor(p_sale_id,p_shift_id);
 return commerce_private.snapshot(s.id)||jsonb_build_object('promo',(select jsonb_build_object('rule',rule,'quote',quote) from commerce_private.redemptions where sale_id=s.id),'employee',(select name from public.sales_employees where id=s.employee_id),'balance',coalesce((select balance from public.loyalty_get_customer(s.loyalty_customer_id)),0),'editable',s.status='completed' and not exists(select 1 from public.sales_returns where sale_id=s.id) and (s.created_at at time zone 'Europe/Moscow')::date=(now() at time zone 'Europe/Moscow')::date);
end $$;
create or replace function commerce_private.edit_sale(p_sale_id bigint,p_shift_id bigint,p_expected_version integer,p_items jsonb,p_discount_percent numeric,p_loyalty_points numeric,p_payment_method text,p_payments jsonb,p_comment text) returns jsonb
language plpgsql security definer set search_path='' as $$
<<edit_values>>
declare s public.sales;before jsonb;it jsonb;pay jsonb;c public.sales_catalog;old_it public.sale_items;new_id bigint;gross numeric:=0;discount numeric;after_discount numeric;points numeric:=round(coalesce(p_loyalty_points,0),2);total numeric;pay_sum numeric:=0;qty numeric;price numeric;balance numeric;old_debt public.customer_debts;due numeric:=0;route bigint;v_variant bigint;earned_delta numeric;available timestamptz;report_shift bigint;edit_ack jsonb:=p_items->0->'_checkout'->'ack';redemption commerce_private.redemptions;promo_quote jsonb;
begin
 s:=commerce_private.actor(p_sale_id,p_shift_id);
 if s.status<>'completed' or (s.created_at at time zone 'Europe/Moscow')::date<>(now() at time zone 'Europe/Moscow')::date then raise exception 'Редактируются только действующие продажи за сегодня';end if;
 if exists(select 1 from public.sales_returns where sale_id=s.id) then raise exception 'У продажи уже есть возврат. Сначала проверьте возвраты';end if;
 select * into redemption from commerce_private.redemptions where sale_id=s.id for update;
 if redemption.id is not null then
  if p_loyalty_points<>0 then raise exception 'Промокод нельзя совмещать со списанием баллов';end if;
  promo_quote:=commerce_private.calculate(redemption.rule,p_items);
  p_items:=promo_quote->'items';p_discount_percent:=(promo_quote->>'discount_percent')::numeric;
 end if;
 perform commerce_private.check_ack(p_items,edit_ack);
 if s.edit_version is distinct from p_expected_version then raise sqlstate 'PT409' using message='Продажа уже изменена другим сотрудником. Откройте её заново';end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Добавьте от 1 до 500 позиций';end if;
 if p_discount_percent is null or p_discount_percent not between 0 and 100 then raise exception 'Скидка должна быть от 0 до 100%%';end if;
 if length(coalesce(p_comment,''))>4000 then raise exception 'Комментарий — не более 4000 символов';end if;
 if p_payment_method not in('cash','card','qr','link','bank_account','transfer','split') or p_payment_method is null then raise exception 'Выберите способ оплаты';end if;
 before:=commerce_private.snapshot(s.id);
 for it in select * from jsonb_array_elements(p_items) loop
  select * into old_it from public.sale_items where id=(it->>'id')::bigint and sale_id=s.id;
  select * into c from public.sales_catalog where id=(it->>'catalog_id')::bigint;
  if c.id is null and (old_it.id is null or old_it.catalog_id is not null) then raise exception 'Товар не найден';end if;
  if c.id is not null and not c.is_active and not exists(select 1 from public.sale_items where sale_id=s.id and catalog_id=c.id) then raise exception 'Товар снят с продажи: %',c.name;end if;
  qty:=(it->>'quantity')::numeric;price:=(it->>'unit_price')::numeric;
  if qty is null or qty<=0 or qty>99999999 or qty<>round(qty,3) or price is null or price<0 or price>99999999 or price<>round(price,2) then raise exception 'Проверьте количество и цену';end if;
  if coalesce(to_jsonb(c)->>'unit','pcs')='pcs' and qty<>trunc(qty) then raise exception 'Количество штучного товара должно быть целым';end if;
  v_variant:=nullif(it->>'variant_material_id','')::bigint;
  if v_variant is not null and not exists(select 1 from public.stock_materials m where m.id=v_variant and (m.variant_catalog_id=c.id or exists(select 1 from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=c.id and n.active))) then raise exception 'Вариант не относится к выбранному товару';end if;
  if v_variant is null and exists(select 1 from public.stock_materials where variant_catalog_id=c.id and not archived) then raise exception 'Выберите размер и цвет товара';end if;
  gross:=gross+round(qty*price,2);
 end loop;
 discount:=round(gross*p_discount_percent/100,2);after_discount:=gross-discount;
 if points<0 or points>round(after_discount*.3,2) then raise exception 'Баллами можно списать не более 30%% после скидки';end if;
 if s.loyalty_customer_id is null and points<>0 then raise exception 'К продаже не привязана клубная карта';end if;
 if s.loyalty_customer_id is not null then
  perform 1 from public.loyalty_customers where id=s.loyalty_customer_id for update;
  select coalesce(sum(t.points),0) into balance from public.loyalty_transactions t where t.customer_id=s.loyalty_customer_id and available_at<=now();
  if points>balance+s.loyalty_points_used then raise exception 'Недостаточно баллов клиента';end if;
 end if;
 total:=round(after_discount-points,2);
 if p_payment_method='split' then
  if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)<2 then raise exception 'Укажите минимум два способа оплаты';end if;
  for pay in select * from jsonb_array_elements(p_payments) loop
   if pay->>'method' not in('cash','card','qr','link','bank_account','transfer') or pay->>'method' is null or (pay->>'amount')::numeric<=0 or (pay->>'amount')::numeric<>round((pay->>'amount')::numeric,2) then raise exception 'Проверьте раздельную оплату';end if;
   pay_sum:=pay_sum+(pay->>'amount')::numeric;if pay->>'method'='bank_account' then due:=due+(pay->>'amount')::numeric;end if;
  end loop;
  if pay_sum<>total then raise exception 'Сумма способов оплаты не равна итогу продажи';end if;
 else p_payments:=case when total>0 then jsonb_build_array(jsonb_build_object('method',p_payment_method,'amount',total)) else '[]'::jsonb end;if p_payment_method='bank_account' then due:=total;end if;end if;
 select * into old_debt from public.customer_debts where sale_id=s.id for update;
 if old_debt.paid_at is not null and due<>old_debt.amount then raise exception 'Долг этой продажи уже погашен. Сумму оплаты по расчётному счёту нужно корректировать отдельно';end if;
 -- Save item history and cancel its old stock usage, retaining the ledger itself.
 update public.stock_moves set cancelled_at=coalesce(cancelled_at,now()),sale_item_id=null where sale_id=s.id and sale_item_id is not null;
 delete from public.sale_items where sale_id=s.id;
 update public.sales set gross_total=gross,discount_percent=p_discount_percent,discount_amount=discount,loyalty_points_used=points,total=edit_values.total,payment_method=p_payment_method,comment=nullif(trim(p_comment),''),
  receipt_issued=case when p_payment_method='link' then case when s.payment_method='link' then s.receipt_issued end else true end,
  payment_status=case when p_payment_method='link' then case when s.payment_method='link' then s.payment_status else 'pending' end else 'paid' end,
  paid_at=case when p_payment_method='link' then case when s.payment_method='link' then s.paid_at end else coalesce(s.paid_at,now()) end,edit_version=edit_version+1 where id=s.id;
 for it in select * from jsonb_array_elements(p_items) loop
  select * into c from public.sales_catalog where id=(it->>'catalog_id')::bigint;
  select * into old_it from jsonb_populate_recordset(null::public.sale_items,before->'items') where id=(it->>'id')::bigint;
  qty:=(it->>'quantity')::numeric;price:=(it->>'unit_price')::numeric;
  insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total,variant_material_id)
  values(s.id,c.id,coalesce(c.item_type,old_it.item_type),coalesce(c.name,old_it.item_name),qty,price,round(qty*price,2),case when c.id is not distinct from old_it.catalog_id then old_it.cost_price else c.cost_price end,
   round(coalesce(case when c.id is not distinct from old_it.catalog_id then old_it.cost_price else c.cost_price end,0)*qty,2),nullif(it->>'variant_material_id','')::bigint) returning id into new_id;
  perform public.stock_redo_item(new_id);
  if old_it.catalog_id is not distinct from c.id then
   select x.branch_id into route from jsonb_populate_recordset(null::public.stock_moves,before->'stock') x join public.stock_materials m on m.id=x.material_id where x.sale_item_id=old_it.id and not m.in_workshop and m.store_branch_id is null order by x.id limit 1;
   if route is not null then update public.stock_moves sm set branch_id=route from public.stock_materials m where sm.sale_item_id=new_id and sm.cancelled_at is null and m.id=sm.material_id and not m.in_workshop and m.store_branch_id is null;end if;
  end if;
 end loop;
 perform public.stock_sale_extra(s.id);
 -- Rebuild the payment split and its debt together, never leaving a partially edited sale.
 delete from public.customer_debts where sale_id=s.id;delete from public.sale_payments where sale_id=s.id;
 for pay in select * from jsonb_array_elements(p_payments) loop
  insert into public.sale_payments(sale_id,payment_method,amount) values(s.id,pay->>'method',(pay->>'amount')::numeric);
 end loop;
 if old_debt.paid_at is not null then update public.customer_debts set paid_at=old_debt.paid_at where sale_id=s.id;end if;
 if s.loyalty_customer_id is not null then
  if s.loyalty_points_used<>points then insert into public.loyalty_transactions(customer_id,transaction_type,order_amount,points,comment,available_at) values(s.loyalty_customer_id,'adjustment',after_discount,s.loyalty_points_used-points,'Изменение списания в продаже №'||s.order_number,now());end if;
  earned_delta:=round(gross*.05,2)-round(coalesce(s.gross_total,s.total+s.loyalty_points_used)*.05,2);
  if earned_delta<>0 then
   select min(t.available_at) into available from public.loyalty_transactions t where t.customer_id=s.loyalty_customer_id and t.transaction_type='purchase' and t.created_at between s.created_at-interval '1 minute' and s.created_at+interval '1 minute' and t.order_amount=s.gross_total;
   insert into public.loyalty_transactions(customer_id,transaction_type,order_amount,points,comment,available_at) values(s.loyalty_customer_id,'adjustment',gross,earned_delta,'Корректировка начисления в продаже №'||s.order_number,coalesce(available,now()+interval '24 hours'));
  end if;
 end if;
 -- Already transferred automatic reports must follow the corrected figures. Manual cells stay untouched.
 select rf.shift_id into report_shift from public.report_fills rf where rf.branch_id=s.branch_id and rf.day=(select (started_at at time zone 'Europe/Moscow')::date from public.sales_shifts where id=s.shift_id) and rf.mode='auto' order by rf.updated_at desc limit 1;
 if redemption.id is not null then update commerce_private.redemptions set quote=promo_quote where id=redemption.id;end if;
 if report_shift is not null then perform public.report_fill_shift(report_shift,'auto');end if;
 insert into commerce_private.sale_edits(sale_id,actor,kind,before_state,after_state) values(s.id,auth.uid(),'edit',before,commerce_private.snapshot(s.id));
 return jsonb_build_object('ok',true,'version',s.edit_version+1);
end $$;

-- Pure price calculation; callers decide which live/snapshotted rule may be used.
create or replace function commerce_private.calculate(p_rule jsonb,p_items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare it jsonb;c public.sales_catalog;q numeric;price numeric;normal_price numeric;line numeric;gross numeric:=0;normal numeric:=0;eligible numeric:=0;discount numeric:=0;price_reduction numeric:=0;items jsonb:='[]';gift_left numeric;gift_qty numeric;gift_id bigint;gift_variant bigint;found_gift boolean:=false;is_eligible boolean;whole boolean:=false;total_qty numeric;t jsonb;
begin
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Добавьте от 1 до 500 позиций';end if;
 gift_id:=(p_rule->>'gift_id')::bigint;gift_qty:=coalesce((p_rule->>'gift_qty')::numeric,1);gift_left:=case when p_rule->>'kind'='gift' then gift_qty else 0 end;
 -- Group duplicate gift rows so re-quoting a zero-priced gift never adds another gift.
 for it in select jsonb_build_object('catalog_id',(x->>'catalog_id')::bigint,'id',min(nullif(x->>'id','')::bigint),'variant_material_id',nullif(x->>'variant_material_id','')::bigint,'quantity',sum((x->>'quantity')::numeric)) from jsonb_array_elements(p_items) x group by (x->>'catalog_id')::bigint,nullif(x->>'variant_material_id','')::bigint order by (x->>'catalog_id')::bigint,nullif(x->>'variant_material_id','')::bigint nulls first loop
  select * into c from public.sales_catalog where id=(it->>'catalog_id')::bigint and is_active;
  if not found then raise exception 'Товар недоступен';end if;
  q:=(it->>'quantity')::numeric;
  if q is null or q<=0 or q>99999999 or q<>round(q,3) then raise exception 'Проверьте количество';end if;
  select sum((x->>'quantity')::numeric) into total_qty from jsonb_array_elements(p_items) x where (x->>'catalog_id')::bigint=c.id;
  normal_price:=c.price;
  for t in select x from jsonb_array_elements(coalesce(c.wholesale_prices,'[]')) x where (x->>'min_qty')::numeric<=total_qty order by (x->>'min_qty')::numeric desc limit 1 loop normal_price:=(t->>'price')::numeric;end loop;
  normal:=normal+round(q*normal_price,2);
  is_eligible:=p_rule->>'kind' in('percent','amount') or(p_rule->>'kind'='products' and (p_rule->'product_ids') @> to_jsonb(array[c.id]));
  whole:=whole or (is_eligible and coalesce((p_rule->>'retail_only')::boolean,true) and normal_price<>c.price);
  price:=case when is_eligible and coalesce((p_rule->>'retail_only')::boolean,true) then c.price else normal_price end;
  if p_rule->>'kind'='gift' and c.id=gift_id and gift_left>0 then
   found_gift:=true;gift_variant:=nullif(it->>'variant_material_id','')::bigint;line:=least(q,gift_left);gift_left:=gift_left-line;q:=q-line;
   items:=items||jsonb_build_array(it||jsonb_build_object('quantity',line,'unit_price',0,'gift',true));
  end if;
  if q>0 then
   if p_rule->>'kind'='products' and is_eligible then price_reduction:=price_reduction+round(q*price,2)-round(q*round(price*(1-(p_rule->>'value')::numeric/100),2),2);price:=round(price*(1-(p_rule->>'value')::numeric/100),2);end if;
   line:=round(q*price,2);gross:=gross+line;
   if p_rule->>'kind' in('percent','amount') or (p_rule->>'kind'='products' and (p_rule->'product_ids') @> to_jsonb(array[c.id])) then eligible:=eligible+case when p_rule->>'kind'='products' then q else line end;end if;
   items:=items||jsonb_build_array(it||jsonb_build_object('quantity',q,'unit_price',price));
  end if;
 end loop;
 if p_rule->>'kind'='gift' and gift_left>0 then
  select * into c from public.sales_catalog where id=gift_id and is_active;
  if not found then raise exception 'Подарок недоступен';end if;
  if gift_variant is null and exists(select 1 from public.stock_materials where variant_catalog_id=c.id and not archived) then raise exception 'Добавьте подарок в продажу и выберите его размер и цвет';end if;
  items:=items||jsonb_build_array(jsonb_build_object('id',null,'catalog_id',gift_id,'variant_material_id',gift_variant,'quantity',gift_left,'unit_price',0,'gift',true));
 end if;
 if p_rule->>'kind'='percent' then discount:=round(eligible*(p_rule->>'value')::numeric/100,2);
 elsif p_rule->>'kind'='amount' then discount:=least(gross,round((p_rule->>'value')::numeric,2));end if;
 if p_rule->>'kind'<>'gift' and eligible<=0 then raise exception 'В продаже нет товаров, подходящих под промокод';end if;
 return jsonb_build_object('items',items,'gross',gross,'discount',discount+price_reduction,'discount_percent',case when gross>0 then discount*100/gross else 0 end,'total',gross-discount,'normal_total',normal,'wholesale',whole,'code',p_rule->>'code','title',p_rule->>'title','version',p_rule->'version');
end $$;

create function commerce_private.quote(p_code text,p_customer uuid,p_items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r commerce_private.promos;
begin
 if not public.is_staff() then raise exception 'Требуется вход сотрудника';end if;
 if p_customer is null or not exists(select 1 from public.loyalty_customers where id=p_customer) then raise exception 'Сначала выберите клубную карту клиента';end if;
 select * into r from commerce_private.promos where code=upper(trim(p_code));
 if not found or not r.active then raise exception 'Промокод не найден или отключён';end if;
 if now()<r.starts_at or now()>=r.ends_at then raise exception 'Промокод не действует в эту дату';end if;
 if exists(select 1 from commerce_private.redemptions where promo_id=r.id and customer_id=p_customer) then raise exception 'Этот промокод уже использован по клубной карте';end if;
 return commerce_private.calculate(to_jsonb(r),p_items);
end $$;

create function commerce_private.manage(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;rid bigint;
begin
 if not public.is_admin() then raise exception 'Доступно только администратору';end if;
 if p_action='list' then return jsonb_build_object('promos',coalesce((select jsonb_agg(to_jsonb(p) order by p.id desc) from commerce_private.promos p),'[]'),'notices',coalesce((select jsonb_agg(to_jsonb(n) order by n.id desc) from commerce_private.notices n),'[]'));end if;
 if p_action='promo' then
  insert into commerce_private.promos(code,title,kind,value,product_ids,gift_id,gift_qty,retail_only,starts_at,ends_at)
  values(upper(trim(p_data->>'code')),trim(p_data->>'title'),p_data->>'kind',coalesce((p_data->>'value')::numeric,0),array(select value::bigint from jsonb_array_elements_text(coalesce(p_data->'product_ids','[]'))),nullif(p_data->>'gift_id','')::bigint,coalesce((p_data->>'gift_qty')::integer,1),coalesce((p_data->>'retail_only')::boolean,true),(p_data->>'starts_at')::timestamptz,(p_data->>'ends_at')::timestamptz) returning id into rid;
 elsif p_action='notice' then
  insert into commerce_private.notices(catalog_id,min_qty,kind,message) values((p_data->>'catalog_id')::bigint,(p_data->>'min_qty')::numeric,p_data->>'kind',trim(p_data->>'message')) returning id into rid;
 elsif p_action='toggle_promo' then update commerce_private.promos set active=(p_data->>'active')::boolean,version=version+1,updated_at=now() where id=(p_data->>'id')::bigint returning id into rid;
 elsif p_action='toggle_notice' then update commerce_private.notices set active=(p_data->>'active')::boolean,version=version+1 where id=(p_data->>'id')::bigint returning id into rid;
 else raise exception 'Неизвестная операция';end if;
 return jsonb_build_object('id',rid);
end $$;
CREATE OR REPLACE FUNCTION commerce_private.checkout_base(p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid DEFAULT NULL::uuid, p_loyalty_points numeric DEFAULT 0, p_loyalty_name text DEFAULT NULL::text, p_loyalty_phone text DEFAULT NULL::text, p_loyalty_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_discount_percent numeric DEFAULT 0, p_payments jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shift public.sales_shifts%rowtype;
  v_sale_id bigint;
  v_order bigint;
  v_gross numeric(12,2):=0;
  v_discount numeric(12,2):=0;
  v_after_discount numeric(12,2):=0;
  v_total numeric(12,2):=0;
  v_points numeric(12,2):=round(coalesce(p_loyalty_points,0),2);
  v_item jsonb; v_pay jsonb; v_catalog public.sales_catalog%rowtype;
  v_qty numeric(12,3); v_price numeric(12,2); v_line numeric(12,2);
  v_pay_sum numeric(12,2):=0; v_customer_id uuid:=p_loyalty_customer_id;
  v_min bigint;
  v_forced bigint:=nullif(current_setting('polaroid.pickup_order',true),'')::bigint;
begin
  select * into v_shift from public.sales_shifts where id=p_shift_id and (status='open' or current_setting('polaroid.offline_sync',true)='1') for update;
  if not found then raise exception 'Смена не найдена или уже закрыта'; end if;
  if not exists(select 1 from public.sales_shift_employees where shift_id=p_shift_id and employee_id=p_employee_id) then raise exception 'Сотрудник не подключён к этой смене'; end if;
  if p_payment_method not in ('cash','card','qr','link','bank_account','transfer','split') then raise exception 'Выберите способ оплаты'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Добавьте хотя бы одну позицию'; end if;
  if coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100 then raise exception 'Скидка должна быть от 0 до 100%%'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_catalog from public.sales_catalog where id=(v_item->>'catalog_id')::bigint and is_active=true;
    if not found then raise exception 'Товар или услуга не найдены'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_price:=coalesce((v_item->>'unit_price')::numeric,v_catalog.price);
    if v_qty<=0 or v_price<0 then raise exception 'Некорректное количество или цена'; end if;
    v_line:=round(v_qty*v_price,2); v_gross:=v_gross+v_line;
  end loop;
  v_discount:=round(v_gross*coalesce(p_discount_percent,0)/100,2);
  v_after_discount:=round(v_gross-v_discount,2);
  if v_points<0 or v_points>round(v_after_discount*0.30,2) then raise exception 'Баллами можно оплатить не более 30%% после скидки'; end if;
  if v_points>0 then
    if v_customer_id is null then raise exception 'Выберите клиента клубной карты'; end if;
    perform public.loyalty_redeem(v_customer_id,v_after_discount,v_points,'Списание баллов при продаже');
  end if;
  v_total:=round(v_after_discount-v_points,2);

  if p_payment_method='split' then
    if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)<2 then raise exception 'Для раздельной оплаты добавьте минимум два способа оплаты'; end if;
    for v_pay in select * from jsonb_array_elements(p_payments) loop
      if (v_pay->>'method') not in ('cash','card','qr','link','bank_account','transfer') then raise exception 'Некорректный способ в раздельной оплате'; end if;
      if coalesce((v_pay->>'amount')::numeric,0)<=0 then raise exception 'Сумма каждого способа оплаты должна быть больше 0'; end if;
      v_pay_sum:=v_pay_sum+round((v_pay->>'amount')::numeric,2);
    end loop;
  else
    v_pay_sum:=v_total;
  end if;
  if round(v_pay_sum,2)<>round(v_total,2) then raise exception 'Сумма способов оплаты должна быть ровно %',v_total; end if;

  insert into public.sales_branch_order_counters(branch_id,next_number) values(v_shift.branch_id,1000) on conflict(branch_id) do nothing;
  select next_number into v_min from public.sales_branch_order_counters where branch_id=v_shift.branch_id for update;
  if v_forced is not null and v_forced=p_order_number
     and not exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_forced) then
    v_order:=v_forced;
  else
    select greatest(v_min, coalesce(max(s.order_number)+1,v_min)) into v_min
    from public.sales s where s.branch_id=v_shift.branch_id;
    v_order:=case when p_order_number is null or p_order_number<v_min then v_min else p_order_number end;
    while exists(select 1 from public.sales s where s.branch_id=v_shift.branch_id and s.order_number=v_order)
       or exists(select 1 from public.pickup_orders o where o.branch_id=v_shift.branch_id and o.order_number=v_order and o.status='pending') loop
      v_order:=v_order+1;
    end loop;
  end if;

  perform set_config('workflow.creator_person',coalesce((select person_id::text from public.sales_employees where id=p_employee_id),''),true);
  if v_gross>0 and v_customer_id is null and nullif(trim(coalesce(p_loyalty_phone,'')),'') is not null then
    select x.customer_id into v_customer_id from public.loyalty_add_purchase(trim(p_loyalty_name),trim(p_loyalty_phone),v_gross,nullif(trim(coalesce(p_loyalty_comment,'')),'')) x limit 1;
  elsif v_gross>0 and v_customer_id is not null then
    select x.customer_id into v_customer_id from public.loyalty_customers c cross join lateral public.loyalty_add_purchase(c.name,c.phone,v_gross,nullif(trim(coalesce(p_loyalty_comment,'')),'')) x where c.id=v_customer_id;
  end if;

  insert into public.sales(order_number,shift_id,branch_id,employee_id,payment_method,total,gross_total,discount_percent,discount_amount,loyalty_points_used,loyalty_customer_id,comment,receipt_issued,payment_status,paid_at)
  values(v_order,v_shift.id,v_shift.branch_id,p_employee_id,p_payment_method,v_total,v_gross,coalesce(p_discount_percent,0),v_discount,v_points,v_customer_id,nullif(trim(coalesce(p_comment,'')),''),case when p_payment_method='link' then null else true end,case when p_payment_method='link' then 'pending' else 'paid' end,case when p_payment_method='link' then null else now() end)
  returning id into v_sale_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_catalog from public.sales_catalog where id=(v_item->>'catalog_id')::bigint;
    v_qty:=(v_item->>'quantity')::numeric; v_price:=(v_item->>'unit_price')::numeric; v_line:=round(v_qty*v_price,2);
    insert into public.sale_items(sale_id,catalog_id,item_type,item_name,quantity,unit_price,line_total,cost_price,cost_total,variant_material_id)
    values(v_sale_id,v_catalog.id,v_catalog.item_type,v_catalog.name,v_qty,v_price,v_line,v_catalog.cost_price,round(coalesce(v_catalog.cost_price,0)*v_qty,2),
      (select m.id from public.stock_materials m where m.id=nullif(v_item->>'variant_material_id','')::bigint and (m.variant_catalog_id=v_catalog.id or exists(select 1 from public.stock_norms n where n.material_id=m.parent_id and n.catalog_id=v_catalog.id and n.active))));
  end loop;
  if p_payment_method='split' then
    for v_pay in select * from jsonb_array_elements(p_payments) loop
      insert into public.sale_payments(sale_id,payment_method,amount) values(v_sale_id,(v_pay->>'method'),round((v_pay->>'amount')::numeric,2));
    end loop;
  elsif v_total>0 then
    insert into public.sale_payments(sale_id,payment_method,amount) values(v_sale_id,p_payment_method,v_total);
  end if;
  update public.sales_branch_order_counters set next_number=greatest(next_number,v_order+1),updated_at=now() where branch_id=v_shift.branch_id;
  return v_order;
end; $function$;

CREATE OR REPLACE FUNCTION public.sales_create_sale(p_shift_id bigint, p_employee_id bigint, p_payment_method text, p_comment text, p_items jsonb, p_loyalty_customer_id uuid DEFAULT NULL::uuid, p_loyalty_points numeric DEFAULT 0, p_loyalty_name text DEFAULT NULL::text, p_loyalty_phone text DEFAULT NULL::text, p_loyalty_comment text DEFAULT NULL::text, p_order_number bigint DEFAULT NULL::bigint, p_discount_percent numeric DEFAULT 0, p_payments jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare meta jsonb:=coalesce(p_items->0->'_checkout','{}');r commerce_private.promos;quote jsonb;ord bigint;sid bigint;cid uuid:=p_loyalty_customer_id;
begin
 if not public.is_staff() then raise exception 'Требуется вход сотрудника';end if;
 if not public.is_admin() and not exists(select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id join public.staff_accounts a on a.person_id=e.person_id where se.shift_id=p_shift_id and a.user_id=auth.uid() and a.active) then raise exception 'Подключитесь к смене из своего аккаунта';end if;
 if nullif(meta->>'code','') is not null then
  if coalesce(p_loyalty_points,0)<>0 then raise exception 'Промокод нельзя совмещать со списанием баллов';end if;
  if cid is null then raise exception 'Сначала выберите клубную карту клиента';end if;
  -- One card lock serializes redemption, including calls from different computers.
  perform 1 from public.loyalty_customers where id=cid for update;
  select * into r from commerce_private.promos where code=upper(trim(meta->>'code')) for share;
  quote:=commerce_private.quote(meta->>'code',cid,p_items);
  if quote->'version' is distinct from meta->'version' or (quote->>'total')::numeric is distinct from (meta->>'total')::numeric then raise exception 'Условия или сумма промокода изменились. Примените его заново';end if;
  p_items:=quote->'items';p_discount_percent:=(quote->>'discount_percent')::numeric;
 end if;
 perform commerce_private.check_ack(p_items,meta->'ack');
 ord:=commerce_private.checkout_base(p_shift_id,p_employee_id,p_payment_method,p_comment,p_items,p_loyalty_customer_id,p_loyalty_points,p_loyalty_name,p_loyalty_phone,p_loyalty_comment,p_order_number,p_discount_percent,p_payments);
 select s.id into sid from public.sales s join public.sales_shifts sh on sh.id=p_shift_id where s.branch_id=sh.branch_id and s.order_number=ord;
 if r.id is not null then insert into commerce_private.redemptions(promo_id,customer_id,sale_id,rule,quote) values(r.id,cid,sid,to_jsonb(r),quote);end if;
 insert into commerce_private.acknowledgements(sale_id,actor,ack) values(sid,auth.uid(),coalesce(meta->'ack','[]'));
 return ord;
end;
$function$;

create function public.commerce_quote(p_code text,p_customer uuid,p_items jsonb) returns jsonb language sql security invoker set search_path='' as $$select commerce_private.quote(p_code,p_customer,p_items)$$;
create function public.commerce_notices(p_items jsonb) returns jsonb language sql security invoker set search_path='' as $$select commerce_private.notices_for(p_items)$$;
create function public.commerce_manage(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select commerce_private.manage(p_action,p_data)$$;
create function public.commerce_get_sale(p_sale_id bigint,p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$select commerce_private.get_sale(p_sale_id,p_shift_id)$$;
create function public.commerce_edit_sale(p_sale_id bigint,p_shift_id bigint,p_expected_version integer,p_items jsonb,p_discount_percent numeric,p_loyalty_points numeric,p_payment_method text,p_payments jsonb,p_comment text) returns jsonb language sql security invoker set search_path='' as $$select commerce_private.edit_sale(p_sale_id,p_shift_id,p_expected_version,p_items,p_discount_percent,p_loyalty_points,p_payment_method,p_payments,p_comment)$$;
create function commerce_private.edit_quote(p_sale_id bigint,p_shift_id bigint,p_items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.sales;r commerce_private.redemptions;
begin
 s:=commerce_private.actor(p_sale_id,p_shift_id);
 select * into r from commerce_private.redemptions where sale_id=s.id;
 if r.id is null then raise exception 'В этой продаже нет промокода';end if;
 return commerce_private.calculate(r.rule,p_items);
end $$;
create function public.commerce_edit_quote(p_sale_id bigint,p_shift_id bigint,p_items jsonb) returns jsonb language sql security invoker set search_path='' as $$select commerce_private.edit_quote(p_sale_id,p_shift_id,p_items)$$;
create function commerce_private.rules() returns jsonb language sql security definer set search_path='' as $$select case when public.is_staff() then coalesce((select jsonb_agg(n) from commerce_private.notices n where active),'[]') end$$;
create function public.commerce_rules() returns jsonb language sql security invoker set search_path='' as $$select commerce_private.rules()$$;
-- Only bounded API implementations are executable by authenticated staff. Internal helpers cannot bypass redemption checks.
do $$declare f record;begin
 for f in select p.oid::regprocedure sig,n.nspname ns,p.proname name from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='commerce_private' or(n.nspname='public' and p.proname like 'commerce_%') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.sig);
  if f.ns='public' or f.name in('quote','notices_for','manage','get_sale','edit_sale','edit_quote','rules') then execute format('grant execute on function %s to authenticated',f.sig);end if;
 end loop;
end $$;
revoke all on function public.sales_create_sale(bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb) from public,anon;
grant execute on function public.sales_create_sale(bigint,bigint,text,text,jsonb,uuid,numeric,text,text,text,bigint,numeric,jsonb) to authenticated;
notify pgrst,'reload schema';

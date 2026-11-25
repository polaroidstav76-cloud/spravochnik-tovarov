const assert=require('node:assert/strict');
module.exports=async db=>{
 const one=async(q,p=[])=>(await db.query(q,p)).rows[0],denies=async(q,p=[],pattern)=>{let err;try{await db.query(q,p);}catch(e){err=e;}assert.ok(err,'Expected rejection');if(pattern)assert.match(err.message,pattern);};
 const uid='11111111-1111-4111-8111-111111111111';
 await db.exec(`insert into auth.users values('${uid}');insert into staff_accounts(user_id,login,name,role,active) values('${uid}','test','Test admin','admin',true);select set_config('request.jwt.claim.sub','${uid}',false);insert into sales_branches(id,name) values(101,'Тест');insert into sales_people(id,name) values(101,'Сотрудник');insert into sales_employees(id,branch_id,person_id,name) values(101,101,101,'Сотрудник');insert into sales_shifts(id,branch_id,employee_id) values(101,101,101);insert into sales_shift_employees(shift_id,employee_id) values(101,101);insert into sales_catalog(id,name,item_type,price,wholesale_prices) values(101,'Фото','product',100,'[{"min_qty":10,"price":95}]'),(102,'Рамка','product',200,'[]');insert into loyalty_customers(name,phone) values('Клиент','79000000001'),('Другой','79000000002');`);
 const card=(await one("select id from loyalty_customers where phone='79000000001'")).id,other=(await one("select id from loyalty_customers where phone='79000000002'")).id;
 const item=(qty=10)=>[{catalog_id:101,quantity:qty,unit_price:95}],manage=async(action,data)=>(await one('select commerce_manage($1,$2) v',[action,JSON.stringify(data)])).v;
 for(const [code,kind,value,extra] of [['P10','percent',10,{}],['FIX','amount',30,{}],['PRODUCT','products',20,{product_ids:[102]}],['GIFT','gift',0,{gift_id:102,gift_qty:2}],['OLD','percent',10,{ends_at:'2001-01-02T00:00Z',starts_at:'2001-01-01T00:00Z'}]])await manage('promo',{code,title:code,kind,value,starts_at:'2020-01-01T00:00Z',ends_at:'2099-01-01T00:00Z',...extra});
 const quote=async(code,rows=item(),customer=card)=>(await one('select commerce_quote($1,$2,$3) v',[code,customer,JSON.stringify(rows)])).v;
 let q=await quote('p10');assert.equal(q.total,900);assert.equal(q.normal_total,950);assert.equal(q.wholesale,true);assert.equal(q.discount,100);
 assert.equal((await quote('FIX',item(1))).total,70);
 q=await quote('PRODUCT',[...item(),{catalog_id:102,quantity:1,unit_price:200}]);assert.equal(q.total,1110,'non-target photo retains wholesale price');assert.equal(q.discount,40);assert.equal(q.discount_percent,0);assert.equal(q.items.find(i=>i.catalog_id===102).unit_price,160,'target discount stays in target item price for correct partial returns');
 q=await quote('GIFT',item(1));assert.equal(q.items.filter(x=>x.gift).reduce((a,x)=>a+x.quantity,0),2);assert.equal(q.total,100);assert.deepEqual((await quote('GIFT',q.items)).items,q.items,'gift quote is idempotent');
 q=await quote('GIFT',[...item(1),{catalog_id:102,quantity:3,unit_price:200}]);assert.equal(q.total,300);assert.equal(q.items.filter(x=>x.catalog_id===102&&!x.gift)[0].quantity,1);
 await denies('select commerce_quote($1,$2,$3)',['OLD',card,JSON.stringify(item())],/дату/);await denies('select commerce_quote($1,null,$2)',['P10',JSON.stringify(item())],/карт/);
 const note=await manage('notice',{catalog_id:101,min_qty:10,kind:'message',message:'Перед оплатой отправьте клиенту сообщение'});
 assert.equal((await one('select commerce_notices($1) v',[JSON.stringify(item(9))])).v.length,0);
 const notices=(await one('select commerce_notices($1) v',[JSON.stringify(item())])).v,ack=notices.map(n=>({id:n.id,version:n.version}));
 async function checkout(code,customer=card,acknowledgements=ack,points=0,client=crypto.randomUUID()){
  const q=await quote(code,item(),customer),rows=q.items.map((i,n)=>n?i:{...i,_checkout:{code:q.code,version:q.version,total:q.total,ack:acknowledgements}});
  return (await one("select sales_create_sale_v6($1,null,101,101,'cash','Тест',$2,p_loyalty_customer_id:=$3,p_loyalty_points:=$4,p_discount_percent:=$5) n",[client,JSON.stringify(rows),customer,points,q.discount_percent])).n;
 }
 await assert.rejects(checkout('P10',card,[]),/предупреждение/);await assert.rejects(checkout('P10',card,ack,1),/балл/);
 const before=(await one('select count(*) n from sales')).n;const client=crypto.randomUUID(),order=await checkout('P10',card,ack,0,client);assert.equal((await one('select count(*) n from sales')).n,before+1);
 let sale=await one('select * from sales where order_number=$1',[order]);assert.equal(Number(sale.total),900);assert.equal((await one('select count(*) n from commerce_private.redemptions')).n,1);
 await denies('select commerce_quote($1,$2,$3)',['P10',card,JSON.stringify(item())],/уже использован/);
 const repeat=await one("select sales_create_sale_v6($1,null,101,101,'cash','Retry',$2,p_loyalty_customer_id:=$3) n",[client,JSON.stringify(item()),card]);assert.equal(repeat.n,order,'uncertain network retries are deduplicated');
 assert.equal((await quote('P10',item(),other)).total,900,'another card may use code');
 const get=async()=>(await one('select commerce_get_sale($1,101) v',[sale.id])).v;let detail=await get();assert.equal(detail.editable,true);assert.equal(detail.promo.rule.code,'P10');
 let edited=detail.items.map(i=>({...i,quantity:20,_checkout:{ack}}));await db.query("select commerce_edit_sale($1,101,0,$2,0,0,'card','[]','Правка')",[sale.id,JSON.stringify(edited)]);sale=await one('select * from sales where id=$1',[sale.id]);assert.equal(Number(sale.total),1800);assert.equal(sale.edit_version,1);assert.equal((await one('select count(*) n from commerce_private.redemptions')).n,1);
 await denies("select commerce_edit_sale($1,101,0,$2,0,0,'card','[]','Conflict')",[sale.id,JSON.stringify(edited)],/другим сотрудником/);
 await denies("select commerce_edit_sale($1,101,1,$2,0,0,'split','[{\"method\":\"cash\",\"amount\":1},{\"method\":\"card\",\"amount\":1}]','Bad split')",[sale.id,JSON.stringify(edited)],/не равна/);assert.equal(Number((await one('select total from sales where id=$1',[sale.id])).total),1800);
 // Original promo rules survive later disabling, but no new uses are accepted.
 const promo=(await manage('list',{})).promos.find(p=>p.code==='P10');await manage('toggle_promo',{id:promo.id,active:false});assert.equal((await one('select commerce_edit_quote($1,101,$2) v',[sale.id,JSON.stringify(edited)])).v.total,1800);await denies('select commerce_quote($1,$2,$3)',['P10',other,JSON.stringify(item())],/отключён/);
 // Normal sale edits recalculate stock and payment without making another sale.
 await db.exec(`insert into stock_materials(id,name,unit) values(101,'Бумага','шт');insert into stock_norms(material_id,catalog_id,qty,active) values(101,101,1,true);`);
 const normal=(await one("select sales_create_sale_v6($1,null,101,101,'cash','Normal',$2) n",[crypto.randomUUID(),JSON.stringify(item(2))])).n,ns=await one('select * from sales where order_number=$1',[normal]);await db.query("select commerce_edit_sale($1,101,0,$2,0,0,'cash','[]','Edited')",[ns.id,JSON.stringify([{catalog_id:101,quantity:3,unit_price:100}])]);assert.equal(Number((await one('select total from sales where id=$1',[ns.id])).total),300);assert.equal(Number((await one('select sum(qty) q from stock_moves where sale_id=$1 and cancelled_at is null',[ns.id])).q),-3);
 await db.exec(`update staff_accounts set role='staff',person_id=101 where user_id='${uid}'`);await denies("select commerce_manage('list','{}')",[],/администратору/);await db.query("select commerce_get_sale($1,101)",[ns.id]);
 await db.exec(`update staff_accounts set person_id=null where user_id='${uid}'`);await denies('select commerce_get_sale($1,101)',[ns.id],/смену/);
 await db.exec("select set_config('request.jwt.claim.sub','',false)");await denies('select commerce_get_sale($1,101)',[ns.id],/вход/);
 const privileges=await db.query("select p.proname,has_function_privilege('anon',p.oid,'execute') anon,has_function_privilege('authenticated',p.oid,'execute') staff from pg_proc p where pronamespace='commerce_private'::regnamespace");for(const p of privileges.rows){assert.equal(p.anon,false);if(['checkout_base','calculate','check_ack','actor','snapshot'].includes(p.proname))assert.equal(p.staff,false);}
 console.log('PASS: 4 promo types, wholesale comparison, gift quantities/idempotency, validity, club, points exclusion, required notices, redemption uniqueness, retry dedup, edit/audit/stock/payments, old promo snapshot, stale edits, staff/admin/anonymous authorization.');
};

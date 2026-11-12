lock table public.loyalty_customers in share row exclusive mode;
do $normalise$
declare before_customers text; before_transactions text; before_count bigint; changed integer; expected integer;
begin
 select count(*),md5(jsonb_agg(to_jsonb(c)-'phone' order by id)::text) into before_count,before_customers from public.loyalty_customers c;
 select md5(jsonb_agg(to_jsonb(t) order by id)::text) into before_transactions from public.loyalty_transactions t;
 with n as(select id,phone,public.loyalty_normalize_phone(phone) normal from public.loyalty_customers)
 select count(*) into expected from n where normal ~ '^79[0-9]{9}$' and phone<>normal and (select count(*) from n x where x.normal=n.normal)=1;
 with n as(select id,public.loyalty_normalize_phone(phone) normal from public.loyalty_customers),
 safe as(select normal from n where normal ~ '^79[0-9]{9}$' group by normal having count(*)=1)
 update public.loyalty_customers c set phone=n.normal from n join safe using(normal) where c.id=n.id and c.phone<>n.normal;
 get diagnostics changed=row_count;
 if changed<>expected or (select count(*) from public.loyalty_customers)<>before_count or
    (select md5(jsonb_agg(to_jsonb(c)-'phone' order by id)::text) from public.loyalty_customers c) is distinct from before_customers or
    (select md5(jsonb_agg(to_jsonb(t) order by id)::text) from public.loyalty_transactions t) is distinct from before_transactions then
    raise exception 'Integrity check failed: phone normalization rolled back';
 end if;
end $normalise$;

-- Долги клиентов по филиалам: сотрудник видит только долги своего филиала, администратор — все.
create or replace function public.debts_list_v2(p_include_paid boolean default false, p_branch_id bigint default null)
returns table(debt_id bigint, sale_id bigint, order_number bigint, sale_created_at timestamptz, branch_id bigint, branch_name text, employee_name text,
  customer_id uuid, customer_name text, customer_phone text, amount numeric, sale_total numeric, paid_at timestamptz, items text)
language sql stable security definer set search_path to 'public' as $fn$
  select d.id, s.id, s.order_number, s.created_at, s.branch_id, b.name, e.name, c.id, c.name, c.phone, d.amount, s.total, d.paid_at,
    (select string_agg(i.item_name||' × '||trim(to_char(i.quantity,'FM999999990.###')),', ' order by i.id) from public.sale_items i where i.sale_id=s.id)
  from public.customer_debts d
  join public.sales s on s.id=d.sale_id
  join public.loyalty_customers c on c.id=d.customer_id
  left join public.sales_branches b on b.id=s.branch_id
  left join public.sales_employees e on e.id=s.employee_id
  where s.status='completed' and (p_include_paid or d.paid_at is null)
    and (p_branch_id is null or s.branch_id=p_branch_id)
  order by c.name, s.created_at;
$fn$;
grant execute on function public.debts_list_v2(boolean, bigint) to anon, authenticated;

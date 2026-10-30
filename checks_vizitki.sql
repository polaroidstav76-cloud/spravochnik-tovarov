-- 2026-10-30: «Оплатить визитки Мастерфото» в «Чеках».
-- Визитки печатает партнёр; сотрудник отмечает, что перевёл оплату. Без отметки строку нельзя поставить «Готово» (на сайте).
set lock_timeout = '5s';
alter table public.branch_checks add column if not exists partner_paid_at timestamptz;
alter table public.branch_checks add column if not exists partner_paid_by text;

-- Вечерняя сводка: визитки без отметки об оплате дольше суток (строки с 30.10.2026, старые не трогаем).
do $do$
declare d text; marker text:=$m$  out:=out||E'\n\n'||case when nprob=0$m$;
begin
  d:=pg_get_functiondef('public.daily_report_text(date)'::regprocedure);
  if position('Визитки не оплачены' in d)>0 then return; end if;
  if position(marker in d)=0 then raise exception 'daily_report_text: не найдено место для вставки'; end if;
  d:=replace(d, marker, $b$  select count(*), string_agg(rep_esc(b.name)||' — '||to_char(c.check_date,'DD.MM')||coalesce(', заказ №'||nullif(btrim(c.order_no),''),'')||': '||rep_esc(left(c.product,60)), E'\n   ' order by c.created_at)
    into cnt, line
  from public.branch_checks c join public.sales_branches b on b.id=c.branch_id
  where c.product ~* 'визитк' and c.partner_paid_at is null and not b.is_test
    and c.created_at>='2026-10-30 00:00+03' and c.created_at<now()-interval '1 day';
  if cnt>0 then nprob:=nprob+1; prob:=prob||E'\n🪪 Визитки не оплачены Мастерфото ('||cnt||E'):\n   '||line; end if;

$b$||marker);
  execute d;
end $do$;

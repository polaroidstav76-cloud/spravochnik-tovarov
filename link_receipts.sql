-- Номер кассового чека по оплатам по ссылке (2026-10-30).
-- При закрытии смены сотрудник вводит номер кассового чека по каждой продаже по ссылке
-- или жмёт «Терминал не работает». Отложенные чеки надо пробить на следующей смене.

alter table public.sales add column if not exists receipt_number text;
alter table public.sales add column if not exists receipt_at timestamptz;
alter table public.sales add column if not exists receipt_by text;
alter table public.sales add column if not exists receipt_deferred_at timestamptz;
alter table public.sales add column if not exists receipt_deferred_by text;

create index if not exists sales_receipt_deferred_idx on public.sales(branch_id)
  where receipt_deferred_at is not null and receipt_number is null;

-- p_number пустой = «Терминал не работает».
create or replace function public.sales_set_link_receipt(p_sale_id bigint, p_number text, p_by text default null)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not public.is_staff() then raise exception 'Нет доступа'; end if;
  if nullif(btrim(p_number),'') is not null then
    update public.sales set receipt_number=left(btrim(p_number),60), receipt_issued=true, receipt_at=now(),
           receipt_by=nullif(btrim(p_by),'')
     where id=p_sale_id;
  else
    update public.sales set receipt_issued=false, receipt_deferred_at=coalesce(receipt_deferred_at,now()),
           receipt_deferred_by=coalesce(receipt_deferred_by,nullif(btrim(p_by),''))
     where id=p_sale_id and receipt_number is null;
  end if;
  return found;
end $$;
grant execute on function public.sales_set_link_receipt(bigint,text,text) to authenticated;

-- Сводка в Телеграм: отложенные чеки по ссылке попадают в «Что не сошлось», пока не пробиты.
do $do$
declare src text; anchor text:=$a$  out:=out||E'\n\n'||case when nprob=0$a$;
begin
  select pg_get_functiondef('public.daily_report_text(date)'::regprocedure) into src;
  if position('receipt_deferred_at' in src)>0 then return; end if;
  if position(anchor in src)=0 then raise exception 'anchor not found'; end if;
  src:=replace(src, anchor, $b$  -- Чеки по ссылке не пробиты: терминал не работал (2026-10-30).
  select count(*), string_agg(rep_esc(b.name)||' — №'||coalesce(x.order_number::text,x.id::text)||' на '||rep_money(x.total)
           ||' от '||to_char(x.created_at at time zone tz,'DD.MM'), E'\n   ' order by x.created_at)
    into cnt, line
  from public.sales x join public.sales_branches b on b.id=x.branch_id
  where x.receipt_deferred_at is not null and x.receipt_number is null
    and x.status='completed' and x.payment_status<>'unpaid' and not b.is_test;
  if cnt>0 then nprob:=nprob+1; prob:=prob||E'\n🧾 Не пробиты чеки по ссылке, терминал не работал ('||cnt||E'):\n   '||line; end if;

$b$||anchor);
  execute src;
end $do$;

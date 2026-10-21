-- Общий отчет: только автоперенос, сотрудник может править (2026-10-21, просьба Рустама).
-- Кнопка «Заполнить отчет вручную» временно скрыта на сайте (код оставлен).
-- В режиме auto сотрудник теперь может менять и клетки кассы (C,D,G,H,I,J,K,L,M,Q).
-- Если он изменил такую клетку — колонка пишется в report_fills.edited_cols, и это видно в Сводке и в отчете в Телеграм.
-- Если он только дописал свои клетки (E,F,N,O,P,R,S) — отметки нет.
-- Исправленные клетки автоперенос больше не перезаписывает.

alter table public.report_fills add column if not exists edited_cols text[] not null default '{}';

create or replace function public.report_auto_cols() returns text[] language sql immutable as $$
  select array['C','D','G','H','I','J','K','L','M','Q']
$$;

create or replace function public.report_staff_cols(p_mode text)
returns text[] language sql immutable as $$
  select case when p_mode in ('auto','manual') then array['C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S']
              else array[]::text[] end
$$;

-- Сотрудник меняет клетку кассы в дне с автопереносом: запомнить колонку, если значение действительно другое.
create or replace function public.report_mark_edit(p_sheet_id bigint, p_row integer, p_branch_id bigint, p_day date, p_col text, p_value jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_old text; v_new text;
begin
  if not (p_col = any(public.report_auto_cols())) then return; end if;
  if not exists(select 1 from public.report_fills where branch_id=p_branch_id and day=p_day and mode='auto') then return; end if;
  select data->'rows'->(p_row::text)->p_col->>'v' into v_old from public.report_sheets where id=p_sheet_id;
  v_old:=btrim(coalesce(v_old,'')); v_new:=btrim(coalesce(p_value#>>'{}',''));
  if v_old=v_new then return; end if;
  if v_old ~ '^-?[0-9]+([.,][0-9]+)?$' and v_new ~ '^-?[0-9]+([.,][0-9]+)?$'
     and replace(v_old,',','.')::numeric=replace(v_new,',','.')::numeric then return; end if;
  update public.report_fills set edited_cols=array(select distinct x from unnest(edited_cols||p_col) x order by 1), updated_at=now()
   where branch_id=p_branch_id and day=p_day;
end $$;
revoke all on function public.report_mark_edit(bigint,integer,bigint,date,text,jsonb) from public, anon, authenticated;

create or replace function public.report_fill_shift(p_shift_id bigint, p_mode text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare c record; d record; v_shifts bigint[]; v_names text; v_vals jsonb; v_skip text[];
begin
  if p_mode not in ('auto','manual') then raise exception 'Неизвестный способ заполнения'; end if;
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no)
    values (p_shift_id,c.branch_id,c.day,p_mode,d.sheet_id,d.row_no)
    on conflict (shift_id) do update set mode=excluded.mode, sheet_id=excluded.sheet_id, row_no=excluded.row_no, updated_at=now();
  if p_mode='auto' then
    select array_agg(id) into v_shifts from public.sales_shifts
     where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=c.day;
    select string_agg(nm,'/' order by first_at) into v_names from (
      select coalesce(nullif(btrim(p.name),''),e.name) nm, min(se.created_at) first_at
        from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
        left join public.sales_people p on p.id=e.person_id
       where se.shift_id=any(v_shifts) group by 1) x;
    with v as (select id,total from public.sales where shift_id=any(v_shifts) and status='completed' and payment_status<>'unpaid'),
         pay as (select p.payment_method m, sum(p.amount) a from public.sale_payments p join v on v.id=p.sale_id group by 1)
    select jsonb_build_object(
      'C', v_names,
      'D', (select coalesce(sum(total),0) from v),
      'G', coalesce((select a from pay where m='card'),0),
      'H', coalesce((select a from pay where m='qr'),0),
      'I', coalesce((select a from pay where m='link'),0),
      'J', coalesce((select a from pay where m='transfer'),0),
      'K', coalesce((select a from pay where m='bank_account'),0),
      'L', (select count(*) from v),
      'M', (select coalesce(sum(amount),0) from public.sales_returns where shift_id=any(v_shifts)),
      'Q', (select coalesce(sum(i.quantity),0) from public.sale_items i join v on v.id=i.sale_id
             where i.item_type='service' and i.item_name ilike '%ретуш%')) into v_vals;
    -- Клетки, которые сотрудник исправил, не перезаписываем.
    select coalesce(array_agg(distinct x),'{}') into v_skip from public.report_fills f, unnest(f.edited_cols) x
     where f.branch_id=c.branch_id and f.day=c.day;
    v_vals:=v_vals-v_skip;
    perform public.report_put_row(d.sheet_id, d.row_no, v_vals);
    perform public.report_recalc_total(d.sheet_id, d.m_to);
  end if;
  return public.report_staff_view(p_shift_id);
end $function$;

create or replace function public.report_staff_set(p_shift_id bigint, p_col text, p_value jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare c record; d record; v_mode text; v_data jsonb;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  select * into d from public.report_day_row(c.branch_id, c.day);
  select mode into v_mode from public.report_fills where shift_id=p_shift_id;
  if v_mode is null then
    select mode into v_mode from public.report_fills where branch_id=c.branch_id and day=c.day order by updated_at desc limit 1;
  end if;
  if v_mode is null then raise exception 'Сначала нажмите «Перенести в общий отчет»'; end if;
  if not (p_col = any(public.report_staff_cols(v_mode))) then raise exception 'Эту клетку заполняет касса'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>500 then raise exception 'Слишком длинный текст'; end if;
  perform public.report_mark_edit(d.sheet_id, d.row_no, c.branch_id, c.day, p_col, p_value);
  perform public.report_put_row(d.sheet_id, d.row_no, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  update public.report_fills set updated_at=now() where shift_id=p_shift_id;
  select data into v_data from public.report_sheets where id=d.sheet_id;
  return jsonb_build_object(d.row_no::text, v_data->'rows'->(d.row_no::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $function$;

create or replace function public.report_staff_set_past(p_shift_id bigint, p_row integer, p_col text, p_value jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare c record; d record; v_data jsonb; v_day date; v_shift bigint;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  if not (p_row = any(public.report_past_rows(d.sheet_id,d.m_from,d.row_no))) then raise exception 'Эту строку менять нельзя'; end if;
  if not (p_col = any(public.report_staff_cols('manual'))) then raise exception 'Эту клетку менять нельзя'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>500 then raise exception 'Слишком длинный текст'; end if;
  select data into v_data from public.report_sheets where id=d.sheet_id;
  v_day:=date '1899-12-30'+(v_data->'rows'->(p_row::text)->'A'->>'v')::numeric::int;
  perform public.report_mark_edit(d.sheet_id, p_row, c.branch_id, v_day, p_col, p_value);
  perform public.report_put_row(d.sheet_id, p_row, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  select data into v_data from public.report_sheets where id=d.sheet_id;
  if not exists(select 1 from public.report_fills where branch_id=c.branch_id and day=v_day) then
    select id into v_shift from public.sales_shifts where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=v_day order by started_at limit 1;
    if v_shift is not null then
      insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no) values (v_shift,c.branch_id,v_day,'manual',d.sheet_id,p_row) on conflict (shift_id) do nothing;
    end if;
  else
    update public.report_fills set updated_at=now() where branch_id=c.branch_id and day=v_day;
  end if;
  return jsonb_build_object(p_row::text, v_data->'rows'->(p_row::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $function$;

-- Отчет в Телеграм: строка «В общем отчете исправили данные кассы». Вставляется после строки про ручное заполнение.
create or replace function public.report_edit_label(p_col text) returns text language sql immutable as $$
  select coalesce(('{"C":"смена","D":"выручка","G":"карта","H":"QR","I":"ссылка","J":"перевод","K":"р/с","L":"чеки","M":"возвраты","Q":"ретушь"}'::jsonb)->>p_col, p_col)
$$;

-- Полная функция (живая версия из базы + новая строка после «заполнен вручную»).
CREATE OR REPLACE FUNCTION public.daily_report_text(p_day date DEFAULT NULL::date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tz constant text:='Europe/Moscow';
  d date:=coalesce(p_day,(now() at time zone tz)::date);
  t0 timestamptz:=d::timestamp at time zone tz;
  t1 timestamptz:=(d+1)::timestamp at time zone tz;
  p0 timestamptz:=(d-7)::timestamp at time zone tz;
  p1 timestamptz:=(d-6)::timestamp at time zone tz;
  months text[]:=array['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря'];
  wd text[]:=array['пн','вт','ср','чт','пт','сб','вс'];
  pm jsonb:='{"cash":"наличные","card":"карта","qr":"QR","transfer":"перевод","link":"ссылка","bank_account":"р/с"}';
  r record; out text; prob text:=''; nprob int:=0;
  rev numeric; cnt int; prev numeric; rets numeric; retc int; line text; exp_cash numeric;
begin
  out:='📊 <b>Сводка за '||extract(day from d)||' '||months[extract(month from d)::int]||' ('||wd[extract(isodow from d)::int]||')</b>'||E'\n';

  select coalesce(sum(total),0), count(*) into rev, cnt from public.sales
   where created_at>=t0 and created_at<t1 and status='completed' and payment_status<>'unpaid' and not public.is_test_branch(branch_id);
  select coalesce(sum(total),0) into prev from public.sales
   where created_at>=p0 and created_at<p1 and status='completed' and payment_status<>'unpaid' and not public.is_test_branch(branch_id);
  select coalesce(sum(amount),0), count(*) into rets, retc from public.sales_returns
   where created_at>=t0 and created_at<t1 and not public.is_test_branch(branch_id);
  out:=out||E'\n💰 Выручка: <b>'||rep_money(rev)||'</b>'||rep_pct(rev,prev)
    ||case when prev>0 then E'\n<i>прошлый '||wd[extract(isodow from d)::int]||': '||rep_money(prev)||'</i>' else '' end
    ||E'\n🧾 Чеков: '||cnt||case when cnt>0 then ' · средний '||rep_money(rev/cnt) else '' end;
  select string_agg(coalesce(pm->>m,m)||' '||rep_money(a),' · ' order by a desc) into line from (
    select p.payment_method m, sum(p.amount) a from public.sale_payments p join public.sales s on s.id=p.sale_id
     where s.created_at>=t0 and s.created_at<t1 and s.status='completed' and s.payment_status<>'unpaid' and not public.is_test_branch(s.branch_id)
     group by 1) x;
  if line is not null then out:=out||E'\n💳 '||line; end if;
  if retc>0 then out:=out||E'\n↩️ Возвраты: '||retc||' на '||rep_money(rets); end if;

  out:=out||E'\n\n🏪 <b>По филиалам</b>';
  for r in
    select b.id, b.name,
      (select coalesce(sum(total),0) from public.sales s where s.branch_id=b.id and s.created_at>=t0 and s.created_at<t1 and s.status='completed' and s.payment_status<>'unpaid') rev,
      (select count(*) from public.sales s where s.branch_id=b.id and s.created_at>=t0 and s.created_at<t1 and s.status='completed' and s.payment_status<>'unpaid') cnt,
      (select coalesce(sum(total),0) from public.sales s where s.branch_id=b.id and s.created_at>=p0 and s.created_at<p1 and s.status='completed' and s.payment_status<>'unpaid') prev,
      (select string_agg(distinct rep_person(se.employee_id),', ') from public.sales_shift_employees se join public.sales_shifts sh on sh.id=se.shift_id
        where sh.branch_id=b.id and sh.started_at>=t0 and sh.started_at<t1) who
    from public.sales_branches b
    where b.is_active and not b.is_test and not b.is_workshop
    order by 3 desc
  loop
    out:=out||E'\n• '||rep_esc(r.name)||': <b>'||rep_money(r.rev)||'</b>'||rep_pct(r.rev,r.prev)||', чеков '||r.cnt
      ||E'\n   '||case when r.who is null then 'смены не было' else 'работали: '||rep_esc(r.who) end;
  end loop;

  for r in
    select sh.*, b.name bname,
      coalesce((select sum(p.amount) from public.sale_payments p join public.sales x on x.id=p.sale_id
                 where x.shift_id=sh.id and x.status='completed' and p.payment_method='cash'),0) cash_sales,
      coalesce((select sum(rt.amount) from public.sales_returns rt join public.sales x on x.id=rt.sale_id
                 where rt.shift_id=sh.id and x.shift_id<>sh.id and x.payment_method='cash'),0) cash_rets
    from public.sales_shifts sh join public.sales_branches b on b.id=sh.branch_id
    where sh.started_at>=t0 and sh.started_at<t1 and not b.is_test
    order by b.name
  loop
    if not public.kassa_cash_check_enabled() then null;
    elsif r.open_cash is null then
      nprob:=nprob+1; prob:=prob||E'\n💵 '||rep_esc(r.bname)||': на открытии смены не указали наличные в кассе';
    elsif r.open_cash_expected is not null and abs(r.open_cash-r.open_cash_expected)>=1 then
      nprob:=nprob+1; prob:=prob||E'\n💵 '||rep_esc(r.bname)||': утром в кассе '||rep_money(r.open_cash)||', а вечером оставили '||rep_money(r.open_cash_expected)
        ||' → <b>'||case when r.open_cash>r.open_cash_expected then '+' else '−' end||rep_money(abs(r.open_cash-r.open_cash_expected))||'</b>'
        ||coalesce(' (открыл(а) '||rep_esc(rep_person(r.open_cash_employee_id))||')','');
    end if;
    if public.kassa_cash_check_enabled() and r.close_cash is not null and r.open_cash is not null then
      exp_cash:=r.open_cash+r.cash_sales-r.cash_rets;
      if abs(r.close_cash-exp_cash)>=1 then
        nprob:=nprob+1; prob:=prob||E'\n💵 '||rep_esc(r.bname)||': при закрытии в кассе '||rep_money(r.close_cash)||', а по продажам должно быть '||rep_money(exp_cash)
          ||' → <b>'||case when r.close_cash>exp_cash then 'лишние +' else 'не хватает −' end||rep_money(abs(r.close_cash-exp_cash))||'</b>'
          ||coalesce(' (закрыл(а) '||rep_esc(rep_person(r.close_cash_employee_id))||')','')
          ||E'\n   <i>утром '||rep_money(r.open_cash)||' + наличные продажи '||rep_money(r.cash_sales)
          ||case when r.cash_rets>0 then ' − возвраты '||rep_money(r.cash_rets) else '' end||'</i>';
      end if;
    end if;
  end loop;

  for r in
    select sh.*, b.name bname from public.sales_shifts sh join public.sales_branches b on b.id=sh.branch_id
    where sh.status='open' and not b.is_test and sh.started_at<t1 order by sh.started_at
  loop
    nprob:=nprob+1; prob:=prob||E'\n🕒 '||rep_esc(r.bname)||': смена не закрыта (открыта '||to_char(r.started_at at time zone tz,'DD.MM HH24:MI')
      ||coalesce(', '||rep_esc(rep_person(r.employee_id)),'')||')';
  end loop;

  for r in
    select rt.*, b.name bname, x.order_number, x.created_at sale_at from public.sales_returns rt join public.sales_branches b on b.id=rt.branch_id
      left join public.sales x on x.id=rt.sale_id
    where rt.created_at>=t0 and rt.created_at<t1 and not b.is_test order by rt.created_at
  loop
    nprob:=nprob+1; prob:=prob||E'\n↩️ '||rep_esc(r.bname)||': возврат '||rep_money(r.amount)||coalesce(', чек №'||r.order_number,'')
      ||case when r.sale_at<t0 then ' от '||to_char(r.sale_at at time zone tz,'DD.MM') else '' end
      ||coalesce(' ('||rep_esc(rep_person(r.employee_id))||')','')||coalesce(' — '||rep_esc(left(nullif(btrim(r.comment),''),80)),'');
  end loop;

  for r in
    select x.*, b.name bname from public.sales x join public.sales_branches b on b.id=x.branch_id
    where x.status='deleted' and coalesce(x.cancelled_at,x.created_at)>=t0 and coalesce(x.cancelled_at,x.created_at)<t1 and not b.is_test order by x.created_at
  loop
    nprob:=nprob+1; prob:=prob||E'\n🗑 '||rep_esc(r.bname)||': удалён чек'||coalesce(' №'||r.order_number,'')||' на '||rep_money(r.total)
      ||coalesce(' ('||rep_esc(rep_person(r.employee_id))||')','')||coalesce(' — '||rep_esc(left(nullif(btrim(r.comment),''),80)),'');
  end loop;

  for r in
    select x.*, b.name bname from public.sales x join public.sales_branches b on b.id=x.branch_id
    where x.created_at>=t0 and x.created_at<t1 and x.status='completed' and not b.is_test
      and (coalesce(x.discount_percent,0)>=15 or coalesce(x.discount_amount,0)>=500) order by x.discount_amount desc nulls last
  loop
    nprob:=nprob+1; prob:=prob||E'\n🏷 '||rep_esc(r.bname)||': скидка '||coalesce(round(r.discount_percent)||'% ','')||'(−'||rep_money(r.discount_amount)||')'
      ||coalesce(', чек №'||r.order_number,'')||' на '||rep_money(r.total)||coalesce(' ('||rep_esc(rep_person(r.employee_id))||')','');
  end loop;

  select string_agg(distinct rep_esc(b.name),', ') into line from public.report_fills f join public.sales_branches b on b.id=f.branch_id
   where f.day=d and f.mode='manual';
  if line is not null then nprob:=nprob+1; prob:=prob||E'\n✍️ Общий отчет заполнен вручную: '||line; end if;

  -- Сотрудник исправил данные кассы после автопереноса (2026-10-21).
  select string_agg(rep_esc(b.name)||' ('||e.labels||')', ', ' order by b.name) into line
  from (select f.branch_id, string_agg(distinct public.report_edit_label(x), ', ') labels
          from public.report_fills f, unnest(f.edited_cols) x where f.day=d group by 1) e
  join public.sales_branches b on b.id=e.branch_id;
  if line is not null then nprob:=nprob+1; prob:=prob||E'\n✏️ В общем отчете исправили данные кассы: '||line; end if;

  select count(*), coalesce(sum(cd.amount),0) into cnt, rev from public.customer_debts cd join public.sales x on x.id=cd.sale_id
   where cd.created_at>=t0 and cd.created_at<t1 and x.status='completed' and not public.is_test_branch(x.branch_id);
  if cnt>0 then nprob:=nprob+1; prob:=prob||E'\n📝 Отдали в долг: '||cnt||' на '||rep_money(rev); end if;

  select count(*), coalesce(sum(total),0) into cnt, rev from public.pickup_orders
   where status='pending' and created_at<now()-interval '2 days' and not public.is_test_branch(branch_id);
  if cnt>0 then nprob:=nprob+1; prob:=prob||E'\n⏳ Не оплачены «при получении» больше 2 дней: '||cnt||' на '||rep_money(rev); end if;

  select string_agg(rep_esc(m.name)||' — '||rep_esc(b.name)||': '||round(q.q,1)||' '||m.unit||' (мин. '||round(m.min_qty,1)||')', E'\n   ' order by b.name, m.name) into line
  from (select material_id, branch_id, sum(qty) q from public.stock_moves where cancelled_at is null group by 1,2
        having bool_or(kind<>'sale')) q
  join public.stock_materials m on m.id=q.material_id join public.sales_branches b on b.id=q.branch_id
  where m.is_active and m.min_qty>0 and q.q<m.min_qty and not b.is_test;
  if line is not null then nprob:=nprob+1; prob:=prob||E'\n📦 Заканчивается:\n   '||line; end if;

  out:=out||E'\n\n'||case when nprob=0 then '✅ <b>Всё сошлось</b>, замечаний нет.' else '⚠️ <b>Что не сошлось ('||nprob||')</b>'||prob end;
  return out;
end $function$;

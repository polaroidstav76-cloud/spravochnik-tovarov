-- Сводка в Telegram: новые пункты сводки + автоповтор отправки. Запустить один раз в Supabase → SQL Editor → Run.
-- Часть 1. Новый текст сводки
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


-- Часть 2. Автоповтор отправки
create table if not exists public.daily_report_log(
  id bigserial primary key,
  day date not null,
  chat_id bigint not null,
  request_id bigint not null,
  created_at timestamptz not null default now()
);
alter table public.daily_report_log enable row level security;

create or replace function public.daily_report_send_one(p_day date, p_chat bigint, p_text text default null)
returns bigint language plpgsql security definer set search_path to 'public' as $function$
declare v_token text; v_text text; v_req bigint;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name='telegram_bot_token';
  if v_token is null then raise exception 'Нет ключа Telegram-бота'; end if;
  v_text:=coalesce(p_text, public.daily_report_text(p_day));
  if length(v_text)>4000 then v_text:=left(v_text,3990)||E'\n…'; end if;
  v_req := net.http_post(
    url:='https://api.telegram.org/bot'||v_token||'/sendMessage',
    headers:='{"Content-Type":"application/json"}'::jsonb,
    body:=jsonb_build_object('chat_id',p_chat,'text',v_text,'parse_mode','HTML','disable_web_page_preview',true),
    timeout_milliseconds:=30000);
  insert into public.daily_report_log(day, chat_id, request_id)
    values (coalesce(p_day,(now() at time zone 'Europe/Moscow')::date), p_chat, v_req);
  return v_req;
end $function$;

create or replace function public.daily_report_send(p_day date default null)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_text text; v_n int:=0; r record;
begin
  v_text:=public.daily_report_text(p_day);
  for r in select chat_id from public.report_recipients where active loop
    perform public.daily_report_send_one(p_day, r.chat_id, v_text);
    v_n:=v_n+1;
  end loop;
  return v_n;
end $function$;

create or replace function public.daily_report_retry()
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_day date := (now() at time zone 'Europe/Moscow')::date; r record; v_n int:=0;
begin
  for r in select rr.chat_id from public.report_recipients rr where rr.active loop
    if exists (select 1 from public.daily_report_log l join net._http_response h on h.id=l.request_id
               where l.day=v_day and l.chat_id=r.chat_id and h.status_code=200) then continue; end if;
    if exists (select 1 from public.daily_report_log l
               where l.day=v_day and l.chat_id=r.chat_id
                 and not exists (select 1 from net._http_response h where h.id=l.request_id)
                 and l.created_at > now() - interval '5 minutes') then continue; end if;
    if (select count(*) from public.daily_report_log l where l.day=v_day and l.chat_id=r.chat_id) >= 8 then continue; end if;
    perform public.daily_report_send_one(null, r.chat_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

revoke all on function public.daily_report_retry() from public, anon, authenticated;
revoke all on function public.daily_report_send_one(date, bigint, text) from public, anon, authenticated;
revoke all on function public.daily_report_send(date) from public, anon, authenticated;

select cron.schedule('daily-report-retry', '10-50/10 18-20 * * *', 'select public.daily_report_retry()');

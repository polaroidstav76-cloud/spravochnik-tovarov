-- 2026-10-14: запрос наличных в кассе при открытии/закрытии смены отправлен в архив (не удалён).
-- Всё управляется одним флагом. Чтобы вернуть проверку:
--   1) create or replace function public.kassa_cash_check_enabled() returns boolean language sql immutable as $$ select true $$;
--   2) в index.html поставить const CASH_CHECK_ENABLED=true;
create or replace function public.kassa_cash_check_enabled() returns boolean language sql immutable as $$ select false $$;
grant execute on function public.kassa_cash_check_enabled() to anon, authenticated;

-- Закрытие смены больше не требует остаток наличных, пока флаг выключен;
-- ежедневная сводка не пишет «не указали наличные» и не сверяет кассу.
do $mig$
declare d text; n text;
begin
  d:=pg_get_functiondef('public.sales_close_team_shift(bigint,bigint)'::regprocedure);
  n:=replace(d,'if v_shift.close_cash is null then','if public.kassa_cash_check_enabled() and v_shift.close_cash is null then');
  if n=d then raise exception 'sales_close_team_shift: место проверки не найдено'; end if;
  execute n;

  d:=pg_get_functiondef('public.daily_report_text(date)'::regprocedure);
  n:=replace(d,'    if r.open_cash is null then','    if not public.kassa_cash_check_enabled() then null;'||chr(10)||'    elsif r.open_cash is null then');
  n:=replace(n,'if r.close_cash is not null and r.open_cash is not null then','if public.kassa_cash_check_enabled() and r.close_cash is not null and r.open_cash is not null then');
  if n=d or position('kassa_cash_check_enabled() and r.close_cash' in n)=0 then raise exception 'daily_report_text: место проверки не найдено'; end if;
  execute n;
end $mig$;

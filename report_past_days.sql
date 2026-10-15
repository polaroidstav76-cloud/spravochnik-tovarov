-- Общий отчет: сотрудник может вручную заполнять и исправлять прошлые дни месяца своего филиала (2026-10-15).
-- Строки прошлых дней (дата в столбце A раньше дня смены, в том же месячном блоке) — клетки C..S, как при ручном заполнении.
-- Если за этот день у филиала ещё не было отметки о заполнении, а смена в тот день была, день отмечается как «заполнен вручную».

-- Номера строк прошлых дней в месячном блоке (по дате в столбце A).
create or replace function public.report_past_rows(p_sheet_id bigint, p_from integer, p_day_row integer) returns integer[]
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(array_agg(k::int order by k::int),array[]::int[]) from public.report_sheets s, jsonb_each(s.data->'rows') as r(k,v)
   where s.id=p_sheet_id and k::int>=p_from and k::int<p_day_row and jsonb_typeof(v->'A'->'v')='number'
$fn$;

create or replace function public.report_staff_view(p_shift_id bigint) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare c record; d record; v_sheet public.report_sheets; v_rows jsonb; v_mode text;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  select * into d from public.report_day_row(c.branch_id, c.day);
  select * into v_sheet from public.report_sheets where id=d.sheet_id;
  select mode into v_mode from public.report_fills where shift_id=p_shift_id;
  if v_mode is null then
    select mode into v_mode from public.report_fills where branch_id=c.branch_id and day=c.day order by updated_at desc limit 1;
  end if;
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into v_rows from jsonb_each(v_sheet.data->'rows') as r(k,v)
   where k::int between d.m_from and d.m_to;
  return jsonb_build_object('title',v_sheet.title,'month',to_char(c.day,'YYYY-MM'),'from',d.m_from,'to',d.m_to,'row',d.row_no,
    'mode',v_mode,'cols',to_jsonb(public.report_staff_cols(v_mode)),
    'past',to_jsonb(public.report_past_rows(d.sheet_id,d.m_from,d.row_no)),'past_cols',to_jsonb(public.report_staff_cols('manual')),
    'data',jsonb_build_object('ncols',v_sheet.data->'ncols','cols',v_sheet.data->'cols','styles',v_sheet.data->'styles',
      'merges',v_sheet.data->'merges','heights',v_sheet.data->'heights','rows',v_rows),
    'updated_at',v_sheet.updated_at);
end $fn$;

-- Сотрудник меняет клетку строки прошлого дня. Возвращает эту строку и строку итога.
create or replace function public.report_staff_set_past(p_shift_id bigint, p_row integer, p_col text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare c record; d record; v_data jsonb; v_day date; v_shift bigint;
begin
  select * into c from public.report_shift_ctx(p_shift_id);
  if public.is_test_branch(c.branch_id) then raise exception 'Тестовый филиал в общий отчет не попадает'; end if;
  select * into d from public.report_day_row(c.branch_id, c.day);
  if not (p_row = any(public.report_past_rows(d.sheet_id,d.m_from,d.row_no))) then raise exception 'Эту строку менять нельзя'; end if;
  if not (p_col = any(public.report_staff_cols('manual'))) then raise exception 'Эту клетку менять нельзя'; end if;
  if p_value is not null and jsonb_typeof(p_value) not in ('number','string','null') then raise exception 'Неверное значение'; end if;
  if jsonb_typeof(p_value)='string' and length(p_value#>>'{}')>500 then raise exception 'Слишком длинный текст'; end if;
  perform public.report_put_row(d.sheet_id, p_row, jsonb_build_object(p_col,p_value));
  perform public.report_recalc_total(d.sheet_id, d.m_to);
  select data into v_data from public.report_sheets where id=d.sheet_id;
  v_day:=date '1899-12-30'+(v_data->'rows'->(p_row::text)->'A'->>'v')::numeric::int;
  if not exists(select 1 from public.report_fills where branch_id=c.branch_id and day=v_day) then
    select id into v_shift from public.sales_shifts where branch_id=c.branch_id and (started_at at time zone 'Europe/Moscow')::date=v_day order by started_at limit 1;
    if v_shift is not null then
      insert into public.report_fills(shift_id,branch_id,day,mode,sheet_id,row_no) values (v_shift,c.branch_id,v_day,'manual',d.sheet_id,p_row) on conflict (shift_id) do nothing;
    end if;
  else
    update public.report_fills set updated_at=now() where branch_id=c.branch_id and day=v_day;
  end if;
  return jsonb_build_object(p_row::text, v_data->'rows'->(p_row::text), d.m_to::text, v_data->'rows'->(d.m_to::text));
end $fn$;

revoke all on function public.report_past_rows(bigint,integer,integer) from public, anon, authenticated;
revoke all on function public.report_staff_set_past(bigint,integer,text,jsonb) from public;
grant execute on function public.report_staff_set_past(bigint,integer,text,jsonb) to anon, authenticated;

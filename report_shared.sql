-- Общий отчет: листы, которые видят все сотрудники (только просмотр, смена не нужна).
-- Админ включает это галочкой «Лист … видят все сотрудники» под листом. Первым открыт лист «ЗАКУПКА».
-- Применено в Supabase 2026-10-17.

alter table public.report_sheets add column if not exists staff_visible boolean not null default false;
update public.report_sheets set staff_visible=true where title='ЗАКУПКА' and not staff_visible;

create or replace function public.report_staff_sheets() returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'data',data) order by sort_order,id),'[]'::jsonb)
  from public.report_sheets where staff_visible and branch_id is null;
$fn$;
revoke all on function public.report_staff_sheets() from public;
grant execute on function public.report_staff_sheets() to anon, authenticated;

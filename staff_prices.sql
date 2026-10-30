-- «Прайс для сотрудников»: список товаров и услуг с ценами (загружен из Excel 2026-10-30).
-- Смотрят все сотрудники, добавляет, редактирует и удаляет позиции только администратор.
create table if not exists public.staff_prices (
  id bigserial primary key,
  name text not null,
  price numeric(12,2) not null default 0,
  note text,
  updated_at timestamptz not null default now()
);

alter table public.staff_prices enable row level security;

create policy "staff_prices_read" on public.staff_prices
  for select to authenticated using (public.is_staff());
create policy "staff_prices_admin_insert" on public.staff_prices
  for insert to authenticated with check (public.is_admin());
create policy "staff_prices_admin_update" on public.staff_prices
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "staff_prices_admin_delete" on public.staff_prices
  for delete to authenticated using (public.is_admin());

grant select, insert, update, delete on public.staff_prices to authenticated;
grant usage on sequence public.staff_prices_id_seq to authenticated;

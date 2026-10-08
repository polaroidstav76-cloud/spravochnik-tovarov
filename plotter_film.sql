-- Цены плёнки для калькулятора «Плоттерная резка».
-- Одна строка = цвет плёнки, размер листа (ширина × длина, см) и цена этого листа.
-- Например: Белая, 30 × 100 см, 3000 ₽ (погонный метр).

create table if not exists public.plotter_film_prices (
  id uuid primary key default gen_random_uuid(),
  color text not null,
  sheet_width_cm numeric not null check (sheet_width_cm > 0),
  sheet_length_cm numeric not null default 100 check (sheet_length_cm > 0),
  price numeric not null check (price >= 0),
  created_at timestamptz not null default now()
);

alter table public.plotter_film_prices enable row level security;

drop policy if exists "plotter_film_prices_read" on public.plotter_film_prices;
create policy "plotter_film_prices_read" on public.plotter_film_prices
  for select to anon, authenticated using (true);

drop policy if exists "plotter_film_prices_admin_write" on public.plotter_film_prices;
create policy "plotter_film_prices_admin_write" on public.plotter_film_prices
  for all to authenticated using (true) with check (true);

grant select on public.plotter_film_prices to anon, authenticated;
grant insert, update, delete on public.plotter_film_prices to authenticated;

-- Цены плёнки для калькулятора «Плоттерная резка».
-- Одна строка = цвет плёнки + размерная ступень «до sheet_width_cm × sheet_length_cm» + цена одного изделия.
-- Ступени заданы в index.html (PLOTTER_TIERS): до 10×15, 15×21, 21×28, 28×40, 28×60, 28×100 см.

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

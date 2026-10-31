-- «Не забудь записать заказ в чеки!»: правила, при которых касса требует записать заказ в «Чеки».
-- kind: item (value = id из sales_catalog), category (value = категория), word (value = слово в названии).
-- min_qty: с какого количества (суммарно по корзине) срабатывает. Смотрят все сотрудники, меняет администратор.
create table if not exists public.check_reminder_rules (
  id bigserial primary key,
  kind text not null check (kind in ('item','category','word')),
  value text not null,
  min_qty integer not null default 1 check (min_qty >= 1),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.check_reminder_rules enable row level security;

create policy "check_reminder_rules_read" on public.check_reminder_rules
  for select to authenticated using (public.is_staff());
create policy "check_reminder_rules_admin_insert" on public.check_reminder_rules
  for insert to authenticated with check (public.is_admin());
create policy "check_reminder_rules_admin_update" on public.check_reminder_rules
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update on public.check_reminder_rules to authenticated;
grant usage on sequence public.check_reminder_rules_id_seq to authenticated;

-- Стартовые правила (согласованы с Рустамом 2026-10-31, дальше он правит сам в «Настройки»).
insert into public.check_reminder_rules (kind, value, min_qty)
select v.kind, v.value, v.min_qty from (values
  ('category','Фотобумага до 30х42 см',100),
  ('category','Широкоформатная печать',1),
  ('word','Визитки',1),
  ('word','Флаеры',1),
  ('word','Стикеры круглые',1),
  ('word','футболк',1),
  ('word','Кружка',1),
  ('word','Аленка',1),
  ('category','Календари',1),
  ('word','Фотопазл',1),
  ('category','УФ ДТФ',1)
) as v(kind, value, min_qty)
where not exists (select 1 from public.check_reminder_rules);

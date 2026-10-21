-- «Список шаблонов для WhatsApp» в разделе «Шаблоны»: таблица на 50 строк (наименование + описание).
-- Применено в Supabase 2026-10-21.
-- Смотрят все сотрудники, заполняет и редактирует только администратор. Строки не удаляются: пустая строка = пустые поля.
create table if not exists public.whatsapp_templates (
  row_no smallint primary key check (row_no between 1 and 50),
  title text,
  description text,
  updated_at timestamptz not null default now()
);

alter table public.whatsapp_templates enable row level security;

create policy "whatsapp_templates_read" on public.whatsapp_templates
  for select to authenticated using (public.is_staff());
create policy "whatsapp_templates_admin_insert" on public.whatsapp_templates
  for insert to authenticated with check (public.is_admin());
create policy "whatsapp_templates_admin_update" on public.whatsapp_templates
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update on public.whatsapp_templates to authenticated;

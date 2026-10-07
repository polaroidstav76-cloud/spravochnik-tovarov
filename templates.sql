-- Шаблоны сообщений для переписки с клиентами.
-- Выполните этот файл один раз в Supabase: SQL Editor -> New query -> вставить -> Run.

create table if not exists public.message_templates (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text,
  body text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.message_templates enable row level security;

-- Сотрудники (без входа) и администратор могут читать шаблоны.
drop policy if exists "message_templates_read" on public.message_templates;
create policy "message_templates_read" on public.message_templates
  for select to anon, authenticated using (true);

-- Создавать, редактировать и удалять шаблоны может только вошедший администратор.
drop policy if exists "message_templates_admin_write" on public.message_templates;
create policy "message_templates_admin_write" on public.message_templates
  for all to authenticated using (true) with check (true);

grant select on public.message_templates to anon, authenticated;
grant insert, update, delete on public.message_templates to authenticated;

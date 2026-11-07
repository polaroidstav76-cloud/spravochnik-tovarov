-- Применить до публикации нового index.html. Обычные объявления остаются обычными.
begin;
alter table public.announcements add column if not exists is_urgent boolean not null default false;
-- RLS продолжает ограничивать чтение; Realtime передаёт только доступные пользователю строки.
do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
    select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='announcements'
  ) then
    alter publication supabase_realtime add table public.announcements;
  end if;
end $$;
commit;

-- Скриншоты в объявлениях (файлы лежат в bucket product-images, папка announcements/)
alter table public.announcements add column if not exists images text[] not null default '{}';

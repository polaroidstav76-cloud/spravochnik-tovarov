-- 2026-10-30: «Комментарий сотрудника» в «Чеках» (под готовностью).
-- Сотрудник пишет комментарий по заказу, сменщик видит его на следующий день: кто написал и когда.
set lock_timeout = '5s';
alter table public.branch_checks add column if not exists staff_comment text;
alter table public.branch_checks add column if not exists staff_comment_by text;
alter table public.branch_checks add column if not exists staff_comment_at timestamptz;

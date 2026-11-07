-- Применить после существующих миграций. Ручная закупка; старые заявки сохраняются.
begin;
alter table public.stock_requests add column if not exists urgent boolean not null default false;

-- Удаляем прежнюю сигнатуру, чтобы PostgREST не выбирал между перегрузками.
drop function if exists public.stock_request_add(bigint,bigint,bigint,text,numeric,bigint,bigint,text);
create or replace function public.stock_request_add(p_shift_id bigint, p_person_id bigint, p_branch_id bigint, p_name text, p_qty numeric,
  p_catalog_id bigint default null, p_material_id bigint default null, p_comment text default null, p_urgent boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare a record; v_b bigint:=p_branch_id; v_id bigint;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if nullif(trim(p_name),'') is null then raise exception 'Напишите, что нужно купить'; end if;
  if p_qty is not null and p_qty<=0 then raise exception 'Количество должно быть больше нуля'; end if;
  if not a.is_admin then
    if v_b is null or (v_b<>a.branch_id and v_b is distinct from public.stock_workshop_id()) then v_b:=a.branch_id; end if;
  end if;
  if v_b is null then raise exception 'Выберите филиал'; end if;
  insert into public.stock_requests(branch_id,person_name,catalog_id,material_id,name,qty,comment,urgent)
  values(v_b,a.person_name,p_catalog_id,p_material_id,trim(p_name),p_qty,nullif(trim(p_comment),''),coalesce(p_urgent,false)) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.stock_request_add(bigint,bigint,bigint,text,numeric,bigint,bigint,text,boolean) from public,anon;
grant execute on function public.stock_request_add(bigint,bigint,bigint,text,numeric,bigint,bigint,text,boolean) to authenticated;

create or replace function public.stock_request_set(p_id bigint,p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Закупку отмечает администратор'; end if;
  if p_status is null or p_status not in ('open','bought','unavailable') then raise exception 'Неизвестный статус'; end if;
  update public.stock_requests set status=p_status,closed_at=case when p_status='bought' then now() else null end where id=p_id;
  if not found then raise exception 'Заявка не найдена'; end if;
end $$;

create or replace function public.stock_purchase_live() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  return jsonb_build_object('at',now(),'rows','[]'::jsonb,'hidden','[]'::jsonb,
    'requests',(select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('unit',m.unit,'code',m.purchase_code,'branch_name',b.name)
      order by (r.status='bought'),r.urgent desc,r.created_at,r.id),'[]'::jsonb)
      from public.stock_requests r left join public.stock_materials m on m.id=r.material_id
      left join public.sales_branches b on b.id=r.branch_id));
end $$;
revoke all on function public.stock_purchase_live(),public.stock_request_set(bigint,text) from public,anon;
grant execute on function public.stock_purchase_live(),public.stock_request_set(bigint,text) to authenticated;
select cron.alter_job(jobid,active:=false) from cron.job where jobname='stock-purchase';

-- Убираем раздел о закупке/заканчивающихся материалах из текущей версии сводки.
-- Проверка шаблона предотвращает незаметное изменение другой версии функции.
do $$
declare d text; a int; b int;
begin
  d:=pg_get_functiondef('public.daily_report_text(date)'::regprocedure);
  a:=strpos(d,'select string_agg(rep_esc(m.name)');
  if a>0 then
    b:=strpos(substr(d,a),'end if;');
    if b=0 then raise exception 'Не найден конец раздела склада в daily_report_text'; end if;
    d:=substr(d,1,a-1)||substr(d,a+b+6);
    execute d;
  elsif strpos(d,'📦 Заканчивается:')>0 then
    raise exception 'Неизвестная версия раздела склада в daily_report_text';
  end if;
end $$;

-- Только серверный обработчик Telegram: разрешённые получатели и актуальный список.
create or replace function public.telegram_purchase_data(p_chat_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists(select 1 from public.report_recipients where chat_id=p_chat_id and active) then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'qty',r.qty,'unit',m.unit,
    'code',m.purchase_code,'branch',b.name,'urgent',r.urgent,'comment',r.comment) order by r.urgent desc,r.created_at,r.id),'[]'::jsonb)
    from public.stock_requests r left join public.stock_materials m on m.id=r.material_id
    left join public.sales_branches b on b.id=r.branch_id where r.status<>'bought');
end $$;
revoke all on function public.telegram_purchase_data(bigint) from public,anon,authenticated;
grant execute on function public.telegram_purchase_data(bigint) to service_role;
commit;

-- Черновики объявлений: база сама записывает новые и изменённые позиции
-- (справочник products и касса sales_catalog). Админ видит их в «Объявлениях»,
-- убирает лишнее и публикует одной кнопкой. Записи не удаляются, только меняют статус.

create table if not exists public.announcement_changes(
  id bigserial primary key,
  source text not null check (source in ('guide','catalog')),
  item_key text not null,
  item_name text not null,
  kind text not null check (kind in ('new','edit','price','off','on')),
  old_price numeric,
  new_price numeric,
  status text not null default 'pending' check (status in ('pending','published','skipped')),
  announcement_id bigint references public.announcements(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists announcement_changes_pending_uq
  on public.announcement_changes(source, item_key, kind) where status='pending';
alter table public.announcement_changes enable row level security;
create policy announcement_changes_admin_read on public.announcement_changes for select to authenticated using (true);
create policy announcement_changes_admin_update on public.announcement_changes for update to authenticated using (true) with check (true);

-- Добавить/склеить изменение. Одна позиция в одном черновике встречается один раз.
create or replace function public.announcement_change_note(p_source text, p_key text, p_name text, p_kind text, p_old numeric default null, p_new numeric default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_opposite text;
begin
  -- Позиция только что добавлена: правки и цены просто уточняют пункт «новое».
  if p_kind in ('edit','price','on','off') and exists(select 1 from announcement_changes where status='pending' and source=p_source and item_key=p_key and kind='new') then
    update announcement_changes set item_name=p_name, new_price=coalesce(p_new,new_price), updated_at=now()
      where status='pending' and source=p_source and item_key=p_key and kind='new';
    if p_kind='off' then
      update announcement_changes set status='skipped', updated_at=now()
        where status='pending' and source=p_source and item_key=p_key and kind='new';
    end if;
    return;
  end if;
  -- Выключили и снова включили (или наоборот) до публикации: изменения нет.
  if p_kind in ('on','off') then
    v_opposite := case p_kind when 'on' then 'off' else 'on' end;
    if exists(select 1 from announcement_changes where status='pending' and source=p_source and item_key=p_key and kind=v_opposite) then
      update announcement_changes set status='skipped', updated_at=now()
        where status='pending' and source=p_source and item_key=p_key and kind=v_opposite;
      return;
    end if;
  end if;
  insert into announcement_changes(source,item_key,item_name,kind,old_price,new_price)
    values(p_source,p_key,p_name,p_kind,p_old,p_new)
  on conflict (source,item_key,kind) where status='pending'
    do update set item_name=excluded.item_name, new_price=excluded.new_price, updated_at=now();
  -- Цену вернули как было: пункт не нужен.
  if p_kind='price' then
    update announcement_changes set status='skipped', updated_at=now()
      where status='pending' and source=p_source and item_key=p_key and kind='price' and old_price is not distinct from new_price;
  end if;
end $$;
revoke all on function public.announcement_change_note(text,text,text,text,numeric,numeric) from public, anon, authenticated;

create or replace function public.announcement_track_products()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    perform announcement_change_note('guide', new.id::text, new.name, 'new');
  elsif new.name is distinct from old.name or new.description is distinct from old.description
     or new.category is distinct from old.category or new.sku is distinct from old.sku then
    perform announcement_change_note('guide', new.id::text, new.name, 'edit');
  end if;
  return null;
end $$;
create or replace trigger announcement_track after insert or update on public.products
  for each row execute function public.announcement_track_products();

create or replace function public.announcement_track_catalog()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    if coalesce(new.is_active,true) then
      perform announcement_change_note('catalog', new.id::text, new.name, 'new', null, new.price);
    end if;
    return null;
  end if;
  if new.is_active is distinct from old.is_active then
    perform announcement_change_note('catalog', new.id::text, new.name, case when coalesce(new.is_active,true) then 'on' else 'off' end, null, new.price);
  end if;
  if new.price is distinct from old.price and coalesce(new.is_active,true) then
    perform announcement_change_note('catalog', new.id::text, new.name, 'price', old.price, new.price);
  end if;
  return null;
end $$;
create or replace trigger announcement_track after insert or update on public.sales_catalog
  for each row execute function public.announcement_track_catalog();

-- Опубликовать выбранные пункты; снятые галочкой пункты помечаются «пропущено».
create or replace function public.announcement_publish_draft(p_title text, p_body text, p_ids bigint[], p_skip bigint[] default '{}')
returns bigint language plpgsql security definer set search_path=public as $$
declare v_id bigint;
begin
  if auth.role() <> 'authenticated' then raise exception 'Только для администратора'; end if;
  if coalesce(trim(p_title),'')='' then raise exception 'Нужен заголовок'; end if;
  insert into announcements(title, body) values(trim(p_title), nullif(trim(p_body),'')) returning id into v_id;
  update announcement_changes set status='published', announcement_id=v_id, updated_at=now()
    where status='pending' and id = any(coalesce(p_ids,'{}'));
  update announcement_changes set status='skipped', updated_at=now()
    where status='pending' and id = any(coalesce(p_skip,'{}'));
  return v_id;
end $$;
revoke all on function public.announcement_publish_draft(text,text,bigint[],bigint[]) from public, anon;
grant execute on function public.announcement_publish_draft(text,text,bigint[],bigint[]) to authenticated;

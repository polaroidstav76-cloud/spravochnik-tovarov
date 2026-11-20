-- Client photo links: private metadata; original bytes live on the owner's Yandex Disk.
create schema if not exists photo_private;
revoke all on schema photo_private from public, anon, authenticated;
create table photo_private.branches (
 branch_id bigint primary key references public.sales_branches(id),
 slug text not null unique default encode(extensions.gen_random_bytes(12),'hex')
);
insert into photo_private.branches(branch_id) select id from public.sales_branches where is_active and not is_test and not is_workshop on conflict do nothing;
create table photo_private.orders (
 id uuid primary key default gen_random_uuid(), token text not null unique default encode(extensions.gen_random_bytes(32),'hex'),
 branch_id bigint not null references public.sales_branches(id), created_by uuid references public.staff_accounts(user_id),
 phone text not null check(phone ~ '^7[0-9]{10}$'), order_number text not null default '',
 source text not null check(source in ('staff','offline')), messenger text check(messenger in ('whatsapp','max')),
 request_id uuid not null unique, status text not null default 'uploading' check(status in ('uploading','complete')),
 mode text check(mode in ('same','different')), comment text not null default '',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), completed_at timestamptz,
 revision integer not null default 0
);
create index on photo_private.orders(branch_id,updated_at desc);
create index on photo_private.orders(created_by,created_at desc);
create index on photo_private.orders(phone);
create table photo_private.groups (
 id uuid primary key default gen_random_uuid(), order_id uuid not null references photo_private.orders(id),
 label text not null check(length(label)<=80), position integer not null,
 unique(order_id,position), unique(id,order_id)
);
create table photo_private.files (
 id uuid primary key, order_id uuid not null references photo_private.orders(id), group_id uuid not null,
 name text not null check(length(name)<=180), size bigint not null check(size>0 and size<=536870912),
 path text not null, status text not null default 'pending' check(status in ('pending','ready','skipped')),
 created_at timestamptz not null default now(), completed_at timestamptz,
 foreign key(group_id,order_id) references photo_private.groups(id,order_id)
);
create index on photo_private.files(order_id,status);
create index on photo_private.files(group_id,order_id);
create table photo_private.settings (id boolean primary key default true check(id), account_id text not null);
alter table photo_private.settings enable row level security;
create table photo_private.rates (key text primary key, hits integer not null, expires_at timestamptz not null);
alter table photo_private.branches enable row level security;
alter table photo_private.orders enable row level security;
alter table photo_private.groups enable row level security;
alter table photo_private.files enable row level security;
alter table photo_private.rates enable row level security;
revoke all on all tables in schema photo_private from public,anon,authenticated;

create or replace function photo_private.api(p_action text,p_data jsonb,p_actor uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 o photo_private.orders%rowtype; f photo_private.files%rowtype; g photo_private.groups%rowtype;
 a public.staff_accounts%rowtype; bid bigint; phone_value text; n integer; secret_id uuid; result jsonb; total bigint;
begin
 -- Only the service-role Edge Function can execute the public invoker wrapper.
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','') <> 'service_role' then
  raise sqlstate 'PT403' using message='Нет доступа';
 end if;
 if p_actor is not null then
  select * into a from public.staff_accounts where user_id=p_actor and active;
  if not found then raise sqlstate 'PT401' using message='Требуется вход сотрудника'; end if;
 end if;
 if p_action='secret' then
  select decrypted_secret into phone_value from vault.decrypted_secrets where name='photo_yandex_token';
  return jsonb_build_object('token',phone_value);
 elsif p_action='configure' then
  if a.role is distinct from 'admin' then raise sqlstate 'PT403' using message='Только администратор'; end if;
  if length(p_data->>'token')<20 or length(p_data->>'token')>1000 then raise exception 'Некорректный токен'; end if;
  if exists(select 1 from photo_private.settings where account_id<>p_data->>'account_id') and exists(select 1 from photo_private.files where status='ready') then raise exception 'На подключённом Диске уже есть фотографии. Для смены аккаунта сначала нужен перенос файлов; обновить токен того же аккаунта можно'; end if;
  insert into photo_private.settings(id,account_id) values(true,p_data->>'account_id') on conflict(id) do update set account_id=excluded.account_id;
  select id into secret_id from vault.secrets where name='photo_yandex_token';
  if secret_id is null then perform vault.create_secret(p_data->>'token','photo_yandex_token','Client photo storage');
  else perform vault.update_secret(secret_id,p_data->>'token'); end if;
  return '{"ok":true}'::jsonb;
 elsif p_action='branches' then
  if p_actor is not null then
   insert into photo_private.branches(branch_id) select id from public.sales_branches where is_active and not is_test and not is_workshop on conflict do nothing;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'slug',pb.slug) order by b.name),'[]') into result
  from photo_private.branches pb join public.sales_branches b on b.id=pb.branch_id
  where b.is_active and not b.is_test and not b.is_workshop and (p_actor is not null or pb.slug=p_data->>'slug');
  return jsonb_build_object('branches',result,'configured',exists(select 1 from vault.secrets where name='photo_yandex_token'),'admin',a.role='admin');
 elsif p_action='rate' then
  delete from photo_private.rates where expires_at<now();
  insert into photo_private.rates values(p_data->>'key',1,now()+interval '1 hour') on conflict(key) do update set hits=photo_private.rates.hits+1 returning hits into n;
  if n>20 then raise exception 'Слишком много новых заявок. Попробуйте позже'; end if;
  return '{"ok":true}';
 elsif p_action='create' then
  phone_value:=regexp_replace(p_data->>'phone','[^0-9]','','g');
  if length(phone_value)=10 then phone_value:='7'||phone_value;
  elsif length(phone_value)=11 and left(phone_value,1)='8' then phone_value:='7'||substr(phone_value,2); end if;
  if phone_value !~ '^7[0-9]{10}$' then raise exception 'Введите телефон: 11 цифр, начиная с 7 или 8'; end if;
  if p_actor is null then
   select b.branch_id into bid from photo_private.branches b join public.sales_branches s on s.id=b.branch_id where b.slug=p_data->>'slug' and s.is_active and not s.is_test and not s.is_workshop;
   if p_data->>'messenger' not in ('whatsapp','max') or p_data->>'messenger' is null then raise exception 'Выберите мессенджер'; end if;
  else
   select branch_id into bid from public.sales_shifts where id=(p_data->>'shift_id')::bigint and ended_at is null;
   if bid is null and a.role='admin' then bid:=(p_data->>'branch_id')::bigint; end if;
  end if;
  if bid is null or not exists(select 1 from public.sales_branches where id=bid and is_active and not is_workshop and not is_test) then raise exception 'Выберите действующий филиал / откройте смену'; end if;
  if length(coalesce(p_data->>'order_number',''))>80 then raise exception 'Слишком длинный номер заказа'; end if;
  select * into o from photo_private.orders where request_id=(p_data->>'request_id')::uuid;
  if found then
   if o.phone<>phone_value or o.branch_id<>bid or o.created_by is distinct from p_actor then raise exception 'Повторите создание ссылки'; end if;
  else
   insert into photo_private.orders(branch_id,created_by,phone,order_number,source,messenger,request_id)
   values(bid,p_actor,phone_value,coalesce(p_data->>'order_number',''),case when p_actor is null then 'offline' else 'staff' end,case when p_actor is null then p_data->>'messenger' end,(p_data->>'request_id')::uuid) returning * into o;
  end if;
  return jsonb_build_object('token',o.token,'id',o.id);
 elsif p_action='list' then
  if p_actor is null then raise sqlstate 'PT401' using message='Требуется вход'; end if;
  select coalesce(jsonb_agg(x),'[]') into result from (
   select ord.id,ord.token,ord.phone,ord.order_number,ord.source,ord.messenger,ord.status,ord.comment,ord.updated_at,ord.completed_at,ord.created_by,
    b.name branch_name,sa.name employee_name,
    (select count(*) from photo_private.files fil where fil.order_id=ord.id and fil.status='ready') file_count,
    (select coalesce(sum(size),0) from photo_private.files fil where fil.order_id=ord.id and fil.status='ready') bytes
   from photo_private.orders ord join public.sales_branches b on b.id=ord.branch_id left join public.staff_accounts sa on sa.user_id=ord.created_by
   where (a.role='admin' or ord.created_by=p_actor or ord.branch_id=(select branch_id from public.sales_shifts where id=(p_data->>'shift_id')::bigint and ended_at is null))
    and (coalesce(p_data->>'search','')='' or ord.phone like '%'||regexp_replace(p_data->>'search','[^0-9]','','g')||'%' and regexp_replace(p_data->>'search','[^0-9]','','g')<>'' or ord.order_number ilike '%'||(p_data->>'search')||'%')
   order by ord.updated_at desc limit 200
  ) x;
  return jsonb_build_object('orders',result);
 end if;
 select * into o from photo_private.orders where token=p_data->>'token' for update;
 if not found then raise sqlstate 'PT404' using message='Ссылка не найдена. Проверьте, что скопировали её целиком'; end if;
 if p_action='internal' then return to_jsonb(o); end if;
 if p_action='manifest' then
  select coalesce(jsonb_agg(jsonb_build_object('id',grp.id,'label',grp.label,'position',grp.position) order by grp.position),'[]') into result from photo_private.groups grp where order_id=o.id;
  return jsonb_build_object('id',o.id,'branch',(select name from public.sales_branches where id=o.branch_id),'phone_hint',right(o.phone,4),'order_number',o.order_number,'source',o.source,'status',o.status,'mode',o.mode,'comment',o.comment,'completed_at',o.completed_at,'revision',o.revision,'groups',result,
   'files',coalesce((select jsonb_agg(jsonb_build_object('id',id,'group_id',group_id,'name',name,'size',size,'status',status) order by created_at,id) from photo_private.files where order_id=o.id and status<>'skipped'),'[]'::jsonb));
 elsif p_action='mode' then
  if exists(select 1 from photo_private.groups where order_id=o.id) and o.mode is distinct from p_data->>'mode' then raise exception 'Размеры уже выбраны для этой ссылки'; end if;
  if p_data->>'mode' not in ('same','different') then raise exception 'Выберите размеры'; end if;
  update photo_private.orders set mode=p_data->>'mode' where id=o.id;
  return '{"ok":true}';
 elsif p_action='reopen' then
  update photo_private.orders set status='uploading',updated_at=now() where id=o.id;
  return '{"ok":true}';
 elsif p_action='group' then
  if o.mode is null then raise exception 'Сначала выберите размеры'; end if;
  if o.status='complete' then raise exception 'Нажмите «Добавить ещё фото»'; end if;
  if o.mode='same' then
   select * into g from photo_private.groups where order_id=o.id limit 1;
   if found then return to_jsonb(g)-'order_id'; end if;
  elsif length(trim(coalesce(p_data->>'label','')))=0 or length(p_data->>'label')>80 then raise exception 'Укажите размер (до 80 символов)'; end if;
  select coalesce(max(position),0)+1 into n from photo_private.groups where order_id=o.id;
  if n>100 then raise exception 'Не более 100 групп размеров в одной ссылке'; end if;
  insert into photo_private.groups(order_id,label,position) values(o.id,case when o.mode='same' then 'Фотографии' else trim(p_data->>'label') end,n) returning * into g;
  return to_jsonb(g)-'order_id';
 elsif p_action='reserve' then
  if o.status='complete' then raise exception 'Нажмите «Добавить ещё фото»'; end if;
  select * into f from photo_private.files where id=(p_data->>'id')::uuid;
  if found then
   if f.order_id<>o.id or f.name<>p_data->>'name' or f.size<>(p_data->>'size')::bigint or f.status='skipped' then raise exception 'Файл уже использован'; end if;
   return to_jsonb(f)||jsonb_build_object('reused',true);
  end if;
  select * into g from photo_private.groups where id=(p_data->>'group_id')::uuid and order_id=o.id;
  if not found then raise exception 'Размер не найден'; end if;
  if length(p_data->>'name') not between 1 and 180 or p_data->>'name' ~ '[/\\]' then raise exception 'Недопустимое имя файла'; end if;
  select count(*),coalesce(sum(size),0) into n,total from photo_private.files where order_id=o.id and status<>'skipped';
  if n>=5000 or total+(p_data->>'size')::bigint>4500000000 then raise exception 'Одна ссылка вмещает до 5000 фото и 4,5 ГБ. Для остальных сотрудник выдаст ещё одну ссылку'; end if;
  insert into photo_private.files(id,order_id,group_id,name,size,path) values((p_data->>'id')::uuid,o.id,g.id,p_data->>'name',(p_data->>'size')::bigint,
   'disk:/Cloudshop-Client-Photos/'||o.id||'/'||lpad(g.position::text,2,'0')||'_'||regexp_replace(g.label,'[^а-яА-ЯёЁa-zA-Z0-9 .х×_-]','_','g')||'/'||left(p_data->>'id',8)||'_'||regexp_replace(p_data->>'name','[[:cntrl:]/\\:*?"<>|]','_','g')) returning * into f;
  update photo_private.orders set updated_at=now() where id=o.id;
  return to_jsonb(f);
 elsif p_action in ('file','complete_file','skip') then
  select * into f from photo_private.files where id=(p_data->>'id')::uuid and order_id=o.id;
  if not found then raise exception 'Файл не найден'; end if;
  if p_action='file' then return to_jsonb(f); end if;
  if p_action='skip' then
   if f.status='ready' then raise exception 'Сохранённые оригиналы не удаляются'; end if;
   update photo_private.files set status='skipped' where id=f.id;
  else
   if f.status='skipped' then raise exception 'Файл исключён из загрузки'; end if;
   update photo_private.files set status='ready',completed_at=coalesce(completed_at,now()) where id=f.id;
  end if;
  update photo_private.orders set updated_at=now() where id=o.id;
  return '{"ok":true}';
 elsif p_action='finish' then
  if exists(select 1 from photo_private.files where order_id=o.id and status='pending') then raise exception 'Дождитесь загрузки всех фото или исключите файлы с ошибкой'; end if;
  if not exists(select 1 from photo_private.files where order_id=o.id and status='ready') then raise exception 'Сначала загрузите фотографии'; end if;
  if p_data ? 'snapshot' and p_data->'snapshot' is distinct from (select coalesce(jsonb_agg(id::text order by id::text),'[]'::jsonb) from photo_private.files where order_id=o.id and status='ready') then raise exception 'Фото изменились в другой вкладке. Обновите страницу и завершите загрузку ещё раз'; end if;
  if length(coalesce(p_data->>'comment',''))>3000 then raise exception 'Комментарий — до 3000 символов'; end if;
  update photo_private.orders set status='complete',comment=coalesce(p_data->>'comment',''),completed_at=now(),updated_at=now(),revision=revision+1 where id=o.id;
  return '{"ok":true}';
 end if;
 raise exception 'Неизвестное действие';
end $$;
revoke all on function photo_private.api(text,jsonb,uuid) from public,anon,authenticated;
grant usage on schema photo_private to service_role;
grant execute on function photo_private.api(text,jsonb,uuid) to service_role;
create or replace function public.photo_links_api(p_action text,p_data jsonb default '{}',p_actor uuid default null)
returns jsonb language sql security invoker set search_path='' as $$ select photo_private.api(p_action,p_data,p_actor) $$;
revoke all on function public.photo_links_api(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.photo_links_api(text,jsonb,uuid) to service_role;
create policy no_client_access on photo_private.branches for all to anon,authenticated using(false) with check(false);
create policy no_client_access on photo_private.orders for all to anon,authenticated using(false) with check(false);
create policy no_client_access on photo_private.groups for all to anon,authenticated using(false) with check(false);
create policy no_client_access on photo_private.files for all to anon,authenticated using(false) with check(false);
create policy no_client_access on photo_private.rates for all to anon,authenticated using(false) with check(false);
create policy no_client_access on photo_private.settings for all to anon,authenticated using(false) with check(false);

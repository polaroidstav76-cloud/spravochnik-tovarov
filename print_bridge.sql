-- Internal 30x40 delivery: paired devices; browser staff never receive download URLs.
set lock_timeout='5s';
create schema if not exists print_private;
revoke all on schema print_private from public,anon;
grant usage on schema print_private to authenticated,service_role;
create table print_private.config(singleton boolean primary key default true check(singleton),branch_id bigint not null references public.sales_branches(id));
insert into print_private.config select true,id from public.sales_branches where name='Тухачевского 26/4' and is_active;
do $$ begin if (select count(*) from print_private.config)<>1 then raise exception 'Printer branch is missing or ambiguous'; end if; end $$;
create table print_private.pairings(code_hash text primary key,role text not null check(role in ('source','receiver')),branch_id bigint not null references public.sales_branches(id),expires_at timestamptz not null,used_at timestamptz,created_by uuid not null references auth.users(id));
create table print_private.devices(id uuid primary key default gen_random_uuid(),role text not null check(role in ('source','receiver')),branch_id bigint not null references public.sales_branches(id),token_hash text not null unique,label text not null,active boolean not null default true,created_at timestamptz not null default now(),last_seen timestamptz);
create unique index print_one_device_per_role on print_private.devices(branch_id,role) where active;
create table print_private.jobs(id uuid primary key,source_device uuid not null references print_private.devices(id),branch_id bigint not null references public.sales_branches(id),filename text not null,size_bytes bigint not null check(size_bytes between 1 and 524288000),sha256 text not null check(sha256~'^[a-f0-9]{64}$'),public_url text not null,source_branch text not null,created_at timestamptz not null default now(),downloaded_at timestamptz,receiver_device uuid references print_private.devices(id),relative_path text);
create index print_pending on print_private.jobs(branch_id,created_at) where downloaded_at is null;
create table print_private.reads(job_id uuid not null references print_private.jobs(id) on delete cascade,user_id uuid not null references auth.users(id) on delete cascade,read_at timestamptz not null default now(),primary key(job_id,user_id));
alter table print_private.config enable row level security;
alter table print_private.pairings enable row level security;
alter table print_private.devices enable row level security;
alter table print_private.jobs enable row level security;
alter table print_private.reads enable row level security;
revoke all on all tables in schema print_private from public,anon,authenticated;
create policy deny_direct_access on print_private.config for all to authenticated using(false) with check(false);
create policy deny_direct_access on print_private.pairings for all to authenticated using(false) with check(false);
create policy deny_direct_access on print_private.devices for all to authenticated using(false) with check(false);
create policy deny_direct_access on print_private.jobs for all to authenticated using(false) with check(false);
create policy deny_direct_access on print_private.reads for all to authenticated using(false) with check(false);

create function print_private.target() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_staff() then raise sqlstate 'PT403' using message='Требуется вход';end if;
 return (select jsonb_build_object('branch_id',c.branch_id,'branch',b.name) from print_private.config c join public.sales_branches b on b.id=c.branch_id);
end $$;
create function public.print_bridge_target() returns jsonb language sql security invoker set search_path='' as $$ select print_private.target(); $$;

create function print_private.make_pair(p_role text) returns jsonb language plpgsql security definer set search_path='' as $$
declare code text:=replace(gen_random_uuid()::text,'-',''); b bigint;
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор'; end if;
 if p_role not in ('source','receiver') then raise exception 'Недопустимый режим'; end if;
 select branch_id into b from print_private.config;
 delete from print_private.pairings where expires_at<now() or used_at is not null;
 insert into print_private.pairings values(encode(sha256(convert_to(code,'UTF8')),'hex'),p_role,b,now()+interval '15 minutes',null,auth.uid());
 return jsonb_build_object('code',code,'expires_at',now()+interval '15 minutes','role',p_role,'branch',(select name from public.sales_branches where id=b));
end $$;
create function public.print_bridge_pair_code(p_role text) returns jsonb language sql security invoker set search_path='' as $$ select print_private.make_pair(p_role); $$;

create function print_private.setup() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор'; end if;
 return jsonb_build_object('branch',(select b.name from print_private.config c join public.sales_branches b on b.id=c.branch_id),'devices',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'role',d.role,'label',d.label,'last_seen',d.last_seen)) from print_private.devices d where d.active),'[]'::jsonb));
end $$;
create function public.print_bridge_setup() returns jsonb language sql security invoker set search_path='' as $$ select print_private.setup(); $$;

create function print_private.revoke_device(p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_admin() then raise sqlstate 'PT403' using message='Только администратор'; end if;
 update print_private.devices set active=false where id=p_id;
 return found;
end $$;
create function public.print_bridge_revoke(p_id uuid) returns boolean language sql security invoker set search_path='' as $$ select print_private.revoke_device(p_id); $$;

create function print_private.allowed_shift(p_shift_id bigint) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_accounts a
 join public.sales_shifts s on s.id=p_shift_id and s.status='open'
 join print_private.config c on c.branch_id=s.branch_id
 where a.user_id=auth.uid() and a.active and (a.role='admin' or exists(
 select 1 from public.sales_shift_employees se join public.sales_employees e on e.id=se.employee_id
 where se.shift_id=s.id and e.person_id=a.person_id and e.is_active)));
$$;
create function print_private.list_files(p_shift_id bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not print_private.allowed_shift(p_shift_id) then raise sqlstate 'PT403' using message='Доступно сотрудникам смены филиала с принтером 30×40'; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.downloaded_at desc) from (
 select j.id,j.filename,j.relative_path,j.source_branch,j.size_bytes,j.downloaded_at,(r.job_id is not null) as is_read
 from print_private.jobs j join print_private.config c on c.branch_id=j.branch_id
 left join print_private.reads r on r.job_id=j.id and r.user_id=auth.uid()
 where j.downloaded_at is not null order by j.downloaded_at desc limit 100) x),'[]'::jsonb);
end $$;
create function public.print_bridge_files(p_shift_id bigint) returns jsonb language sql security invoker set search_path='' as $$ select print_private.list_files(p_shift_id); $$;
create function print_private.mark_read(p_shift_id bigint,p_job_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not print_private.allowed_shift(p_shift_id) then raise sqlstate 'PT403' using message='Нет доступа'; end if;
 if not exists(select 1 from print_private.jobs j join print_private.config c on c.branch_id=j.branch_id where j.id=p_job_id and j.downloaded_at is not null) then raise exception 'Файл не найден'; end if;
 insert into print_private.reads(job_id,user_id) values(p_job_id,auth.uid()) on conflict do nothing;
 return true;
end $$;
create function public.print_bridge_read(p_shift_id bigint,p_job_id uuid) returns boolean language sql security invoker set search_path='' as $$ select print_private.mark_read(p_shift_id,p_job_id); $$;

create function print_private.device_api(p_action text,p_token text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d print_private.devices; p print_private.pairings; j print_private.jobs; token text; hash text; job_id uuid;
begin
 if p_action='pair' then
  if coalesce(p_payload->>'code','')!~'^[a-f0-9]{32}$' then raise sqlstate 'PT401' using message='Неверный или истёкший код'; end if;
  select * into p from print_private.pairings where code_hash=encode(sha256(convert_to(p_payload->>'code','UTF8')),'hex') and used_at is null and expires_at>now() for update;
  if not found then raise sqlstate 'PT401' using message='Неверный или истёкший код'; end if;
  if p.role<>coalesce(p_payload->>'expected_role','') then raise sqlstate 'PT403' using message='Код другого режима';end if;
  update print_private.pairings set used_at=now() where code_hash=p.code_hash;
  update print_private.devices set active=false where branch_id=p.branch_id and role=p.role and active;
  token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into print_private.devices(role,branch_id,token_hash,label) values(p.role,p.branch_id,encode(sha256(convert_to(token,'UTF8')),'hex'),left(coalesce(p_payload->>'label','Компьютер'),80)) returning * into d;
  return jsonb_build_object('token',token,'role',d.role,'branch',(select name from public.sales_branches where id=d.branch_id));
 end if;
 if coalesce(p_token,'')!~'^[a-f0-9]{64}$' then raise sqlstate 'PT401' using message='Компьютер не подключён'; end if;
 select * into d from print_private.devices where active and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found then raise sqlstate 'PT401' using message='Доступ компьютера отключён'; end if;
 update print_private.devices set last_seen=now() where id=d.id;
 if p_action='health' then return jsonb_build_object('ok',true,'role',d.role,'branch',(select name from public.sales_branches where id=d.branch_id)); end if;
 if p_action='enqueue' then
  if d.role<>'source' then raise sqlstate 'PT403' using message='Неверный режим компьютера'; end if;
  job_id:=(p_payload->>'id')::uuid;
  if coalesce(p_payload->>'filename','')='' or length(p_payload->>'filename')>180 or (p_payload->>'filename')~E'[/\\\\[:cntrl:]]' or (p_payload->>'filename') in ('.','..') then raise exception 'Недопустимое название файла'; end if;
  if coalesce(p_payload->>'url','')!~'^https://(disk[.]yandex[.](ru|com)|yadi[.]sk)/' then raise exception 'Недопустимый адрес файла'; end if;
  if coalesce(p_payload->>'sha256','')!~'^[a-f0-9]{64}$' then raise exception 'Нет контрольной суммы'; end if;
  insert into print_private.jobs(id,source_device,branch_id,filename,size_bytes,sha256,public_url,source_branch)
   values(job_id,d.id,d.branch_id,p_payload->>'filename',(p_payload->>'size')::bigint,p_payload->>'sha256',p_payload->>'url',left(coalesce(p_payload->>'source_branch',''),120)) on conflict do nothing;
  select * into j from print_private.jobs where id=job_id;
  if j.branch_id<>d.branch_id or j.sha256<>p_payload->>'sha256' or j.filename<>p_payload->>'filename' or j.size_bytes<>(p_payload->>'size')::bigint then raise exception 'Состав задания изменился'; end if;
  return jsonb_build_object('id',j.id,'downloaded',j.downloaded_at is not null);
 end if;
 if p_action='status' then
  if d.role<>'source' then raise sqlstate 'PT403' using message='Неверный режим компьютера'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'downloaded',downloaded_at is not null)) from print_private.jobs where branch_id=d.branch_id and id in(select value::uuid from jsonb_array_elements_text(coalesce(p_payload->'ids','[]')))),'[]'::jsonb);
 end if;
 if d.role<>'receiver' then raise sqlstate 'PT403' using message='Неверный режим компьютера'; end if;
 if p_action='next' then
  select * into j from print_private.jobs where branch_id=d.branch_id and downloaded_at is null order by created_at limit 1;
  if not found then return null; end if;
  return jsonb_build_object('id',j.id,'filename',j.filename,'size',j.size_bytes,'sha256',j.sha256,'url',j.public_url);
 end if;
 if p_action='complete' then
  select * into j from print_private.jobs where id=(p_payload->>'id')::uuid and branch_id=d.branch_id for update;
  if not found then raise exception 'Задание не найдено'; end if;
  if j.sha256<>coalesce(p_payload->>'sha256','') or j.size_bytes<>coalesce((p_payload->>'size')::bigint,0) then raise exception 'Файл не прошёл проверку'; end if;
  if length(coalesce(p_payload->>'relative_path','')) not between 1 and 360 or (p_payload->>'relative_path')~E'(^|[/\\\\])[.][.]([/\\\\]|$)|^[A-Za-z]:|^[\\\\/]' then raise exception 'Недопустимый путь файла'; end if;
  update print_private.jobs set downloaded_at=coalesce(downloaded_at,now()),receiver_device=coalesce(receiver_device,d.id),relative_path=coalesce(relative_path,p_payload->>'relative_path') where id=j.id;
  return jsonb_build_object('downloaded',true);
 end if;
 raise exception 'Неизвестное действие';
end $$;
create function public.print_bridge_device_api(p_action text,p_token text,p_payload jsonb) returns jsonb language sql security invoker set search_path='' as $$ select print_private.device_api(p_action,p_token,p_payload); $$;

revoke all on all functions in schema print_private from public,anon,authenticated;
grant execute on function print_private.target(),print_private.make_pair(text),print_private.setup(),print_private.revoke_device(uuid),print_private.list_files(bigint),print_private.mark_read(bigint,uuid) to authenticated;
grant execute on function print_private.device_api(text,text,jsonb) to service_role;
revoke all on function public.print_bridge_target(),public.print_bridge_pair_code(text),public.print_bridge_setup(),public.print_bridge_revoke(uuid),public.print_bridge_files(bigint),public.print_bridge_read(bigint,uuid),public.print_bridge_device_api(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.print_bridge_target(),public.print_bridge_pair_code(text),public.print_bridge_setup(),public.print_bridge_revoke(uuid),public.print_bridge_files(bigint),public.print_bridge_read(bigint,uuid) to authenticated;
grant execute on function public.print_bridge_device_api(text,text,jsonb) to service_role;

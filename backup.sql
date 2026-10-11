-- Ежедневная резервная копия базы. Применено в Supabase 2026-10-11.
-- Каждую ночь в 03:00 по Москве pg_cron вызывает Edge Function daily-backup (supabase/functions/daily-backup),
-- она сохраняет все таблицы public в приватный бакет Storage «backups» файлом ГГГГ-ММ-ДД.json.gz и хранит 60 последних копий.
-- Токен лежит в Vault (backup_token); без него функция ничего не отдаёт.

create extension if not exists pg_cron;
create extension if not exists pg_net;

insert into storage.buckets(id,name,public) values('backups','backups',false) on conflict(id) do update set public=false;

do $$ begin
  if not exists(select 1 from vault.secrets where name='backup_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24),'hex'),'backup_token','Токен ежедневной резервной копии');
  end if;
end $$;

create or replace function public.backup_snapshot(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t record; v jsonb:='{}'::jsonb; rows jsonb;
begin
  if p_token is null or p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name='backup_token') then
    raise exception 'forbidden';
  end if;
  for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='public' and c.relkind in ('r','p') order by c.relname loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from public.%I x',t.relname) into rows;
    v:=v||jsonb_build_object(t.relname,rows);
  end loop;
  return jsonb_build_object('created_at',now(),'project','tmxluzvymwldtxbaiekn','tables',v);
end; $$;
revoke all on function public.backup_snapshot(text) from public, anon, authenticated;
grant execute on function public.backup_snapshot(text) to service_role;

create or replace function public.backup_run()
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  select net.http_post(
    url:='https://tmxluzvymwldtxbaiekn.supabase.co/functions/v1/daily-backup',
    headers:=jsonb_build_object('Content-Type','application/json','x-backup-token',(select decrypted_secret from vault.decrypted_secrets where name='backup_token')),
    body:='{}'::jsonb,
    timeout_milliseconds:=120000) into v_id;
  return v_id;
end; $$;
revoke all on function public.backup_run() from public, anon, authenticated;

select cron.unschedule('daily-backup') where exists(select 1 from cron.job where jobname='daily-backup');
select cron.schedule('daily-backup','0 0 * * *','select public.backup_run()');

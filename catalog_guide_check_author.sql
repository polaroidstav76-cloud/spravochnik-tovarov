set lock_timeout='5s';
alter table public.sales_catalog add column guide_product_id uuid references public.products(id) on delete set null;
create index sales_catalog_guide_product_idx on public.sales_catalog(guide_product_id);
alter table public.branch_checks add column created_by_name text;
update public.branch_checks b set created_by_name=coalesce(nullif(p.name,''),nullif(a.name,''),a.login) from public.staff_accounts a left join public.sales_people p on p.id=a.person_id where a.user_id=b.created_by;
create schema if not exists check_author_private;
revoke all on schema check_author_private from public,anon,authenticated;
create function check_author_private.stamp() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' then new.created_by:=old.created_by;new.created_by_name:=old.created_by_name;new.created_at:=old.created_at;return new;end if;
 if auth.uid() is not null then new.created_by:=auth.uid();end if;
 select coalesce(nullif(p.name,''),nullif(a.name,''),a.login) into new.created_by_name from public.staff_accounts a left join public.sales_people p on p.id=a.person_id where a.user_id=new.created_by;
 new.created_at:=now();return new;
end $$;
revoke all on function check_author_private.stamp() from public,anon,authenticated;
create trigger branch_checks_stamp_author before insert or update on public.branch_checks for each row execute function check_author_private.stamp();

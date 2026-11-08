create or replace function public.purchase_free_request_add(
  p_shift_id bigint,p_person_id bigint,p_branch_id bigint,p_name text,p_code text default null,
  p_qty numeric default null,p_urgent boolean default false,p_comment text default null
) returns bigint language plpgsql security definer set search_path='' as $$
declare a record; rid bigint;
begin
  if not public.is_staff() then raise exception 'Требуется вход сотрудника'; end if;
  select * into a from public.stock_actor(p_shift_id,p_person_id);
  if not a.is_admin and p_branch_id is distinct from a.branch_id and p_branch_id is distinct from public.stock_workshop_id() then
    raise exception 'Выберите свой филиал';
  end if;
  if p_branch_id is null or not exists(select 1 from public.sales_branches where id=p_branch_id) then raise exception 'Выберите филиал'; end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>250 then raise exception 'Укажите название до 250 символов'; end if;
  if length(coalesce(p_code,''))>50 then raise exception 'Код слишком длинный'; end if;
  if p_qty is not null and (p_qty<=0 or p_qty>999999 or p_qty<>round(p_qty,3)) then raise exception 'Укажите положительное количество'; end if;
  if length(coalesce(p_comment,''))>1000 then raise exception 'Комментарий слишком длинный'; end if;
  insert into public.stock_requests(branch_id,person_name,name,qty,urgent,comment,supplier_code)
  values(p_branch_id,a.person_name,trim(p_name),p_qty,coalesce(p_urgent,false),nullif(trim(p_comment),''),nullif(trim(p_code),'')) returning id into rid;
  return rid;
end $$;
revoke all on function public.purchase_free_request_add(bigint,bigint,bigint,text,text,numeric,boolean,text) from public,anon;
grant execute on function public.purchase_free_request_add(bigint,bigint,bigint,text,text,numeric,boolean,text) to authenticated;


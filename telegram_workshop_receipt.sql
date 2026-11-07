-- После stock_manual_purchase.sql и workshop.sql; до обновления telegram-purchase.
-- Количество в штуках увеличивает остаток мастерской, сумма — стоимость всей покупки.
begin;
create table if not exists public.telegram_receipt_sessions(
  chat_id bigint primary key,
  started_at timestamptz not null default now()
);
create table if not exists public.telegram_receipt_messages(
  chat_id bigint not null,
  message_id bigint not null,
  move_id bigint not null references public.stock_moves(id),
  primary key(chat_id,message_id)
);
create index if not exists telegram_receipt_messages_move_id_idx on public.telegram_receipt_messages(move_id);
alter table public.telegram_receipt_sessions enable row level security;
alter table public.telegram_receipt_messages enable row level security;
revoke all on public.telegram_receipt_sessions,public.telegram_receipt_messages from public,anon,authenticated;

-- Удаляем прежнюю сигнатуру, если ранняя версия уже применялась.
drop function if exists public.telegram_workshop_receipt(bigint,bigint,text,text,numeric);

-- Состояние диалога хранится в базе, а не в памяти Edge Function.
create or replace function public.telegram_workshop_receipt(
  p_chat_id bigint,p_message_id bigint,p_action text,p_name text default null,p_amount numeric default null,p_qty numeric default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_move bigint; v_material bigint; v_branch bigint; v_person text; v_started timestamptz; v_unit text; v_active boolean;
begin
  select coalesce(name,'Telegram') into v_person from public.report_recipients where chat_id=p_chat_id and active;
  if not found or p_chat_id<=0 then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended('telegram-receipt:'||p_chat_id::text,0));
  if p_action='start' then
    insert into public.telegram_receipt_sessions(chat_id) values(p_chat_id)
      on conflict(chat_id) do update set started_at=now();
    return jsonb_build_object('status','ready');
  elsif p_action='cancel' then
    delete from public.telegram_receipt_sessions where chat_id=p_chat_id;
    return jsonb_build_object('status','cancelled');
  elsif p_action<>'save' then
    raise exception 'Неизвестное действие';
  end if;
  -- Повтор Telegram после сбоя отправки ответа не создаёт второй приход.
  select move_id into v_move from public.telegram_receipt_messages where chat_id=p_chat_id and message_id=p_message_id;
  if found then return jsonb_build_object('status','saved','id',v_move); end if;
  select started_at into v_started from public.telegram_receipt_sessions where chat_id=p_chat_id;
  if not found then return jsonb_build_object('status','inactive'); end if;
  if v_started<now()-interval '24 hours' then
    delete from public.telegram_receipt_sessions where chat_id=p_chat_id;
    return jsonb_build_object('status','expired');
  end if;
  if p_message_id is null or p_message_id<=0 or nullif(trim(p_name),'') is null or length(trim(p_name))>200
    or p_qty is null or p_qty<=0 or p_qty>999999999 or p_qty<>round(p_qty,3)
    or p_amount is null or p_amount<=0 or p_amount>999999999.99 or p_amount<>round(p_amount,2) then
    return jsonb_build_object('status','invalid');
  end if;
  v_branch:=public.stock_workshop_id();
  if v_branch is null then raise exception 'Мастерская не настроена'; end if;
  -- Сериализуем создание одинаковых названий от разных получателей.
  perform pg_advisory_xact_lock(hashtextextended('telegram-material:'||lower(trim(p_name)),0));
  select id,unit,(is_active and not archived) into v_material,v_unit,v_active from public.stock_materials where lower(name)=lower(trim(p_name));
  if v_material is null then
    insert into public.stock_materials(name,in_workshop) values(trim(p_name),true) returning id into v_material;
  else
    if not v_active then return jsonb_build_object('status','inactive_material'); end if;
    if lower(trim(v_unit)) not in ('шт','шт.','штука','штуки','штук') then
      return jsonb_build_object('status','unit_mismatch');
    end if;
  end if;
  insert into public.stock_moves(material_id,branch_id,qty,kind,group_id,price_total,comment,person_name)
    values(v_material,v_branch,p_qty,'receipt',gen_random_uuid(),p_amount,
      'Приход в мастерскую из Telegram. Сумма — общая стоимость покупки.',v_person)
    returning id into v_move;
  insert into public.telegram_receipt_messages(chat_id,message_id,move_id) values(p_chat_id,p_message_id,v_move);
  return jsonb_build_object('status','saved','id',v_move);
end $$;
revoke all on function public.telegram_workshop_receipt(bigint,bigint,text,text,numeric,numeric) from public,anon,authenticated;
grant execute on function public.telegram_workshop_receipt(bigint,bigint,text,text,numeric,numeric) to service_role;
commit;

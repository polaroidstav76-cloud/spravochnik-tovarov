alter table payroll_private.fine_sessions add column reason text;
create or replace function payroll_private.telegram_flow(p_chat_id bigint,p_message_id bigint,p_action text,p_text text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare s payroll_private.fine_sessions%rowtype;person public.sales_people%rowtype;matches jsonb;n integer;value numeric;name_input text;parts text[];fid uuid;existing payroll_private.fines%rowtype;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 if not exists(select 1 from public.report_recipients where chat_id=p_chat_id and active) then return jsonb_build_object('status','inactive');end if;
 perform pg_advisory_xact_lock(hashtextextended('payroll-fine:'||p_chat_id,0));
 select * into existing from payroll_private.fines where telegram_chat_id=p_chat_id and telegram_message_id=p_message_id;
 if found then select * into person from public.sales_people where id=existing.person_id;return jsonb_build_object('status','saved','name',person.name,'amount',existing.amount,'reason',existing.reason);end if;
 select * into s from payroll_private.fine_sessions where chat_id=p_chat_id for update;
 if s.last_message_id>=p_message_id then return jsonb_build_object('status','ignored');end if;
 if p_action='cancel' then delete from payroll_private.fine_sessions where chat_id=p_chat_id;return jsonb_build_object('status',case when found then 'cancelled' else 'inactive' end);end if;
 if p_action='start' then
  insert into payroll_private.fine_sessions(chat_id,step,person_id,amount,last_message_id,expires_at) values(p_chat_id,'name',null,null,p_message_id,now()+interval '30 minutes') on conflict(chat_id) do update set step='name',person_id=null,amount=null,reason=null,last_message_id=excluded.last_message_id,expires_at=excluded.expires_at;
  return jsonb_build_object('status','name');
 end if;
 if s.chat_id is null then return jsonb_build_object('status','inactive');end if;
 if s.expires_at<now() then delete from payroll_private.fine_sessions where chat_id=p_chat_id;return jsonb_build_object('status','expired');end if;
 update payroll_private.fine_sessions set last_message_id=p_message_id where chat_id=p_chat_id;
 if s.step='name' then
  name_input:=trim(p_text);parts:=regexp_match(name_input,'^(.+?)[[:space:]]+([0-9]+([.,][0-9]{1,2})?)[[:space:]]*(руб[.]?|₽)?$');
  if parts is not null then name_input:=trim(parts[1]);value:=replace(parts[2],',','.')::numeric;end if;
  select count(*),jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name,p.id) into n,matches from public.sales_people p where p.is_active and (lower(trim(p.name))=lower(trim(name_input)) or (name_input ~ '^#[0-9]+$' and '#'||p.id=name_input));
  if n=0 then select count(*),jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name,p.id) into n,matches from public.sales_people p where p.is_active and position(lower(trim(name_input)) in lower(p.name))>0 and length(trim(name_input))>=2;end if;
  if n=1 then select * into person from public.sales_people where id=(matches->0->>'id')::bigint;if parts is not null then if value<=0 or value>999999999 then return jsonb_build_object('status','bad_amount');end if;update payroll_private.fine_sessions set person_id=person.id,amount=value,step='reason' where chat_id=p_chat_id;return jsonb_build_object('status','reason','name',person.name,'amount',value);end if;update payroll_private.fine_sessions set person_id=person.id,step='amount' where chat_id=p_chat_id;return jsonb_build_object('status','amount','name',person.name);end if;
  return jsonb_build_object('status','choose','people',coalesce((select jsonb_agg(x) from(select candidate.value x from jsonb_array_elements(matches)candidate limit 30)q),'[]'::jsonb));
 elsif s.step='amount' then
  if trim(p_text) !~ '^[0-9]+([.,][0-9]{1,2})?$' then return jsonb_build_object('status','bad_amount');end if;
  value:=replace(trim(p_text),',','.')::numeric;if value<=0 or value>999999999 then return jsonb_build_object('status','bad_amount');end if;
  select * into person from public.sales_people where id=s.person_id and is_active;if not found then delete from payroll_private.fine_sessions where chat_id=p_chat_id;return jsonb_build_object('status','expired');end if;
  update payroll_private.fine_sessions set amount=value,step='reason' where chat_id=p_chat_id;
  return jsonb_build_object('status','reason','name',person.name,'amount',value);
 elsif s.step='reason' then
  if p_action='confirm' or length(trim(coalesce(p_text,'')))=0 or length(p_text)>500 then return jsonb_build_object('status','bad_reason');end if;
  select * into person from public.sales_people where id=s.person_id;
  update payroll_private.fine_sessions set reason=trim(p_text),step='confirm' where chat_id=p_chat_id;
  return jsonb_build_object('status','confirm','name',person.name,'amount',s.amount,'reason',trim(p_text));
 elsif s.step='confirm' then
  if nullif(trim(s.reason),'') is null then update payroll_private.fine_sessions set step='reason' where chat_id=p_chat_id;return jsonb_build_object('status','reason');end if;
  if p_action<>'confirm' then return jsonb_build_object('status','await_confirm');end if;
  select * into person from public.sales_people where id=s.person_id and is_active;if not found then return jsonb_build_object('status','expired');end if;
  insert into payroll_private.fines(person_id,amount,reason,telegram_chat_id,telegram_message_id) values(s.person_id,s.amount,s.reason,p_chat_id,p_message_id) returning id into fid;
  delete from payroll_private.fine_sessions where chat_id=p_chat_id;
  return jsonb_build_object('status','saved','id',fid,'name',person.name,'amount',s.amount,'reason',s.reason);
 end if;
 return jsonb_build_object('status','inactive');
end $$;

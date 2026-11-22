-- Remove a ready photo from the order. Edge moves originals/print output outside downloadable folders first.
do $$begin execute replace(pg_get_functiondef('photo_private.api(text,jsonb,uuid)'::regprocedure),'FUNCTION photo_private.api(','FUNCTION photo_private.api_before_photo_remove(');end $$;
revoke all on function photo_private.api_before_photo_remove(text,jsonb,uuid) from public,anon,authenticated;
create or replace function photo_private.api(p_action text,p_data jsonb,p_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o photo_private.orders%rowtype;f photo_private.files%rowtype;r photo_private.renders%rowtype;op uuid;
begin
 if p_action not in ('remove_begin','remove_commit') then return photo_private.api_before_photo_remove(p_action,p_data,p_actor);end if;
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role','')<>'service_role' then raise sqlstate 'PT403' using message='Нет доступа';end if;
 select * into o from photo_private.orders where token=p_data->>'token' for update;if not found then raise sqlstate 'PT404' using message='Ссылка не найдена';end if;
 select * into f from photo_private.files where order_id=o.id and id=(p_data->>'id')::uuid for update;if not found then raise sqlstate 'PT404' using message='Фото не найдено';end if;
 if f.status='skipped' then return '{"ok":true,"removed":true}';end if;
 if f.status<>'ready' then raise exception 'Дождитесь окончания загрузки этого фото';end if;
 op:=(p_data->>'operation_id')::uuid;if op is null then raise exception 'Повторите удаление';end if;
 if p_action='remove_begin' then
  if f.publish_until>now() and f.publish_id is distinct from op then raise sqlstate 'PT409' using message='Фото ещё сохраняется. Повторите удаление через несколько секунд';end if;
  update photo_private.files set publish_id=op,publish_until=now()+interval '3 minutes' where id=f.id;
  select * into r from photo_private.renders where id=f.render_id;
  return jsonb_build_object('order_id',o.id,'path',f.path,'target',r.target);
 end if;
 if f.publish_id is distinct from op then raise sqlstate 'PT409' using message='Повторите удаление фотографии';end if;
 update photo_private.files set status='skipped',crop_draft=null,render_id=null,crop_revision=crop_revision+1,publish_id=null,publish_until=null where id=f.id;
 update photo_private.orders set updated_at=now(),status='uploading' where id=o.id;
 return '{"ok":true,"removed":true}';
end $$;
revoke all on function photo_private.api(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function photo_private.api(text,jsonb,uuid) to service_role;
notify pgrst,'reload schema';

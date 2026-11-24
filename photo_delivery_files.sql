do $$begin execute replace(pg_get_functiondef('photo_private.api(text,jsonb,uuid)'::regprocedure),'FUNCTION photo_private.api(','FUNCTION photo_private.api_before_delivery(');end $$;
revoke all on function photo_private.api_before_delivery(text,jsonb,uuid) from public,anon,authenticated;
create or replace function photo_private.api(p_action text,p_data jsonb,p_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o jsonb;files jsonb;
begin
 if p_action<>'delivery_files' then return photo_private.api_before_delivery(p_action,p_data,p_actor);end if;
 o:=photo_private.api_before_delivery('internal',p_data,null);
 if exists(select 1 from photo_private.files f left join photo_private.renders r on r.id=f.render_id where f.order_id=(o->>'id')::uuid and f.status<>'skipped' and (f.status='pending' or f.publish_until>now() or (f.crop_draft is not null and (f.render_id is null or f.crop_draft is distinct from r.settings)))) then raise exception 'Дождитесь загрузки и сохранения всех фотографий';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'group',g.label,'position',g.position,'render_id',f.render_id,'path',case when f.render_id is not null then r.path else f.path end,'size',case when f.render_id is not null then r.size else f.size end,'cropped',f.render_id is not null) order by g.position,f.created_at,f.id),'[]'::jsonb) into files from photo_private.files f join photo_private.groups g on g.id=f.group_id left join photo_private.renders r on r.id=f.render_id where f.order_id=(o->>'id')::uuid and f.status='ready';
 return jsonb_build_object('id',o->>'id','comment',o->>'comment','order_number',o->>'order_number','files',files);
end $$;
revoke all on function photo_private.api(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function photo_private.api(text,jsonb,uuid) to service_role;
notify pgrst,'reload schema';

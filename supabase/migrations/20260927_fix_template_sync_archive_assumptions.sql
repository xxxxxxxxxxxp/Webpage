-- The live Template Topic/Subtopic schema has no archived/active state.
-- Official membership for those entities is row existence; admin removal is a physical delete.
create or replace function public.preview_academic_template_update(requested_template_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare imp public.academic_template_imports%rowtype; current_revision integer;
begin
  imp := public.current_academic_template_import(requested_template_id);
  select revision into current_revision from public.academic_templates where id = requested_template_id;
  if current_revision is null then return jsonb_build_object('deleted_template', true); end if;
  return jsonb_build_object(
    'template_id', requested_template_id, 'installed_revision', coalesce(imp.last_synced_revision, 1), 'latest_revision', current_revision,
    'added_topics', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'code', t.code)) from public.academic_template_topics t where t.template_id = requested_template_id and not exists (select 1 from public.academic_template_entity_mappings m where m.import_id = imp.id and m.entity_type = 'topic' and m.template_entity_id = t.id and m.detached_at is null)), '[]'::jsonb),
    'updated_topics', '[]'::jsonb,
    'removed_topics', coalesce((select jsonb_agg(jsonb_build_object('template_id', m.template_entity_id, 'personal_id', m.personal_entity_id, 'name', p.name, 'action_default', 'keep')) from public.academic_template_entity_mappings m join public.academic_topics p on p.id = m.personal_entity_id and p.owner_id = auth.uid() where m.import_id = imp.id and m.entity_type = 'topic' and m.detached_at is null and not exists (select 1 from public.academic_template_topics t where t.id = m.template_entity_id and t.template_id = requested_template_id)), '[]'::jsonb),
    'added_subtopics', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'topic_id', s.topic_id)) from public.academic_template_subtopics s where s.template_id = requested_template_id and not exists (select 1 from public.academic_template_entity_mappings m where m.import_id = imp.id and m.entity_type = 'subtopic' and m.template_entity_id = s.id and m.detached_at is null)), '[]'::jsonb),
    'updated_subtopics', '[]'::jsonb,
    'removed_subtopics', coalesce((select jsonb_agg(jsonb_build_object('template_id', m.template_entity_id, 'personal_id', m.personal_entity_id, 'action_default', 'keep')) from public.academic_template_entity_mappings m join public.academic_subtopics p on p.id = m.personal_entity_id and p.owner_id = auth.uid() where m.import_id = imp.id and m.entity_type = 'subtopic' and m.detached_at is null and not exists (select 1 from public.academic_template_subtopics s where s.id = m.template_entity_id and s.template_id = requested_template_id)), '[]'::jsonb),
    'added_task_types', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'reward_points', t.reward_points)) from public.academic_template_task_types t where t.template_id = requested_template_id and t.active = true and not exists (select 1 from public.academic_template_entity_mappings m where m.import_id = imp.id and m.entity_type = 'task_type' and m.template_entity_id = t.id and m.detached_at is null)), '[]'::jsonb),
    'updated_task_types', '[]'::jsonb, 'removed_task_types', '[]'::jsonb,
    'added_skill_tags', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name)) from public.academic_template_skill_tags s where s.template_id = requested_template_id and s.active = true and not exists (select 1 from public.academic_template_entity_mappings m where m.import_id = imp.id and m.entity_type = 'skill_tag' and m.template_entity_id = s.id and m.detached_at is null)), '[]'::jsonb),
    'updated_skill_tags', '[]'::jsonb, 'removed_skill_tags', '[]'::jsonb,
    'added_resources', '[]'::jsonb, 'updated_resources', '[]'::jsonb, 'removed_resources', '[]'::jsonb
  );
end $$;

create or replace function public.apply_academic_template_update(requested_template_id uuid, removal_decisions jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare imp public.academic_template_imports%rowtype; current_revision integer; item record; decision text;
begin
  imp := public.current_academic_template_import(requested_template_id);
  select revision into current_revision from public.academic_templates where id = requested_template_id;
  if current_revision is null then raise exception 'Template no longer exists'; end if;
  for item in select m.* from public.academic_template_entity_mappings m where m.import_id = imp.id and m.detached_at is null loop
    if item.entity_type = 'topic' and not exists (select 1 from public.academic_template_topics t where t.id = item.template_entity_id and t.template_id = requested_template_id) then
      decision := coalesce(removal_decisions #>> array['removed_topics', item.template_entity_id::text], 'keep');
      if decision = 'delete' then delete from public.academic_topics where id = item.personal_entity_id and owner_id = auth.uid(); else update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id; update public.academic_topics set origin_template_topic_id = null where id = item.personal_entity_id and owner_id = auth.uid(); end if;
    elsif item.entity_type = 'subtopic' and not exists (select 1 from public.academic_template_subtopics s where s.id = item.template_entity_id and s.template_id = requested_template_id) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_subtopics set origin_template_subtopic_id = null where id = item.personal_entity_id and owner_id = auth.uid();
    elsif item.entity_type = 'task_type' and not exists (select 1 from public.academic_template_task_types t where t.id = item.template_entity_id and t.template_id = requested_template_id and t.active = true) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_task_types set origin_template_task_type_id = null where id = item.personal_entity_id and owner_id = auth.uid();
    elsif item.entity_type = 'skill_tag' and not exists (select 1 from public.academic_template_skill_tags s where s.id = item.template_entity_id and s.template_id = requested_template_id and s.active = true) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_skill_tags set origin_template_skill_tag_id = null where id = item.personal_entity_id and owner_id = auth.uid();
    end if;
  end loop;
  update public.academic_template_imports set last_synced_revision = current_revision, last_synced_at = now() where id = imp.id;
  return jsonb_build_object('template_id', requested_template_id, 'revision', current_revision);
end $$;

grant execute on function public.preview_academic_template_update(uuid) to authenticated;
grant execute on function public.apply_academic_template_update(uuid, jsonb) to authenticated;

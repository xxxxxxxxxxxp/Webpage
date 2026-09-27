-- Fix sync ownership lookup: academic_template_imports is not guaranteed to have owner_id.
-- Ownership is read defensively from the import row's supported account fields, never from client input.
create or replace function public.current_academic_template_import(requested_template_id uuid)
returns public.academic_template_imports language plpgsql security definer set search_path = public as $$
declare result public.academic_template_imports%rowtype; row_json jsonb;
begin
  for result in select * from public.academic_template_imports where template_id = requested_template_id loop
    row_json := to_jsonb(result);
    if coalesce(row_json->>'owner_id', row_json->>'user_id', row_json->>'student_id', row_json->>'imported_by') = auth.uid()::text then return result; end if;
  end loop;
  raise exception 'Template is not installed for the current account';
end $$;

create or replace function public.preview_academic_template_update(requested_template_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare imp public.academic_template_imports%rowtype; current_revision integer;
begin
  imp := public.current_academic_template_import(requested_template_id);
  select revision into current_revision from public.academic_templates where id = requested_template_id;
  if current_revision is null then return jsonb_build_object('deleted_template', true); end if;
  return jsonb_build_object('template_id', requested_template_id, 'installed_revision', coalesce(imp.last_synced_revision, 1), 'latest_revision', current_revision,
    'added_topics', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name)) from public.academic_template_topics t where t.template_id = requested_template_id and not t.archived and not exists (select 1 from public.academic_template_entity_mappings m where m.import_id = imp.id and m.entity_type = 'topic' and m.template_entity_id = t.id and m.detached_at is null)), '[]'::jsonb),
    'updated_topics', '[]'::jsonb, 'removed_topics', coalesce((select jsonb_agg(jsonb_build_object('template_id', m.template_entity_id, 'personal_id', m.personal_entity_id, 'name', p.name, 'action_default', 'keep')) from public.academic_template_entity_mappings m join public.academic_topics p on p.id = m.personal_entity_id and p.owner_id = auth.uid() where m.import_id = imp.id and m.entity_type = 'topic' and m.detached_at is null and not exists (select 1 from public.academic_template_topics t where t.id = m.template_entity_id and not t.archived)), '[]'::jsonb),
    'added_task_types', '[]'::jsonb, 'updated_task_types', '[]'::jsonb, 'removed_task_types', '[]'::jsonb, 'added_subtopics', '[]'::jsonb, 'updated_subtopics', '[]'::jsonb, 'removed_subtopics', '[]'::jsonb, 'added_skill_tags', '[]'::jsonb, 'updated_skill_tags', '[]'::jsonb, 'removed_skill_tags', '[]'::jsonb, 'added_resources', '[]'::jsonb, 'updated_resources', '[]'::jsonb, 'removed_resources', '[]'::jsonb);
end $$;

create or replace function public.apply_academic_template_update(requested_template_id uuid, removal_decisions jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare imp public.academic_template_imports%rowtype; current_revision integer;
begin
  imp := public.current_academic_template_import(requested_template_id);
  select revision into current_revision from public.academic_templates where id = requested_template_id;
  if current_revision is null then raise exception 'Template no longer exists'; end if;
  update public.academic_template_imports set last_synced_revision = current_revision, last_synced_at = now() where id = imp.id;
  return jsonb_build_object('template_id', requested_template_id, 'revision', current_revision);
end $$;

revoke all on function public.current_academic_template_import(uuid) from public;
grant execute on function public.preview_academic_template_update(uuid) to authenticated;
grant execute on function public.apply_academic_template_update(uuid, jsonb) to authenticated;

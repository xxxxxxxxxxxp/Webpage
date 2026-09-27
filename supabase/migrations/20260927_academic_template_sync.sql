-- Additive template revision and stable-origin support. Existing student copies remain independent.
alter table public.academic_templates add column if not exists revision integer not null default 1;
alter table public.academic_template_imports add column if not exists last_synced_revision integer;
alter table public.academic_template_imports add column if not exists last_synced_at timestamptz;

alter table public.academic_task_types add column if not exists origin_template_task_type_id uuid;
alter table public.academic_topics add column if not exists origin_template_topic_id uuid;
alter table public.academic_subtopics add column if not exists origin_template_subtopic_id uuid;
alter table public.academic_skill_tags add column if not exists origin_template_skill_tag_id uuid;
alter table public.academic_resources add column if not exists origin_template_resource_id uuid;

create index if not exists academic_task_types_origin_template_idx on public.academic_task_types(origin_template_task_type_id) where origin_template_task_type_id is not null;
create index if not exists academic_topics_origin_template_idx on public.academic_topics(origin_template_topic_id) where origin_template_topic_id is not null;
create index if not exists academic_subtopics_origin_template_idx on public.academic_subtopics(origin_template_subtopic_id) where origin_template_subtopic_id is not null;
create index if not exists academic_skill_tags_origin_template_idx on public.academic_skill_tags(origin_template_skill_tag_id) where origin_template_skill_tag_id is not null;
create index if not exists academic_resources_origin_template_idx on public.academic_resources(origin_template_resource_id) where origin_template_resource_id is not null;

-- This supplements origin columns for historical imports whose schema did not record every origin.
create table if not exists public.academic_template_entity_mappings (
  import_id uuid not null references public.academic_template_imports(id) on delete cascade,
  entity_type text not null check (entity_type in ('task_type','topic','subtopic','skill_tag','resource')),
  template_entity_id uuid not null,
  personal_entity_id uuid not null,
  detached_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (import_id, entity_type, template_entity_id),
  unique (import_id, entity_type, personal_entity_id)
);

-- Keeps new imports revision-aware even when the existing import RPC inserts the import row unchanged.
create or replace function public.set_academic_template_import_revision()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.last_synced_revision is null then
    select revision into new.last_synced_revision from public.academic_templates where id = new.template_id;
  end if;
  if new.last_synced_at is null then new.last_synced_at := now(); end if;
  return new;
end $$;
drop trigger if exists academic_template_import_revision_before_insert on public.academic_template_imports;
create trigger academic_template_import_revision_before_insert before insert on public.academic_template_imports
for each row execute function public.set_academic_template_import_revision();

-- Called once after an admin logical save. It is intentionally not a row trigger, so a multi-row save increments once.
create or replace function public.touch_academic_template_revision(requested_template_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare next_revision integer;
begin
  if auth.uid() is null or not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Administrator access is required';
  end if;
  update public.academic_templates set revision = revision + 1 where id = requested_template_id returning revision into next_revision;
  if next_revision is null then raise exception 'Template not found'; end if;
  return next_revision;
end $$;

-- Read-only comparison; mappings, not labels, identify managed student entities.
create or replace function public.preview_academic_template_update(requested_template_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare imp public.academic_template_imports%rowtype; current_revision integer;
begin
  select * into imp from public.academic_template_imports where template_id = requested_template_id and owner_id = auth.uid() limit 1;
  if imp.id is null then raise exception 'Template is not installed'; end if;
  select revision into current_revision from public.academic_templates where id = requested_template_id;
  if current_revision is null then return jsonb_build_object('deleted_template', true); end if;
  return jsonb_build_object(
    'template_id', requested_template_id, 'installed_revision', coalesce(imp.last_synced_revision, 1), 'latest_revision', current_revision,
    'added_topics', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name)) from public.academic_template_topics t where t.template_id = requested_template_id and not t.archived and not exists (select 1 from public.academic_template_entity_mappings m where m.import_id = imp.id and m.entity_type = 'topic' and m.template_entity_id = t.id and m.detached_at is null)), '[]'::jsonb),
    'updated_topics', '[]'::jsonb,
    'removed_topics', coalesce((select jsonb_agg(jsonb_build_object('template_id', m.template_entity_id, 'personal_id', m.personal_entity_id, 'name', p.name, 'action_default', 'keep')) from public.academic_template_entity_mappings m join public.academic_topics p on p.id = m.personal_entity_id where m.import_id = imp.id and m.entity_type = 'topic' and m.detached_at is null and not exists (select 1 from public.academic_template_topics t where t.id = m.template_entity_id and not t.archived)), '[]'::jsonb),
    'added_task_types', '[]'::jsonb, 'updated_task_types', '[]'::jsonb, 'removed_task_types', '[]'::jsonb,
    'added_subtopics', '[]'::jsonb, 'updated_subtopics', '[]'::jsonb, 'removed_subtopics', '[]'::jsonb,
    'added_skill_tags', '[]'::jsonb, 'updated_skill_tags', '[]'::jsonb, 'removed_skill_tags', '[]'::jsonb,
    'added_resources', '[]'::jsonb, 'updated_resources', '[]'::jsonb, 'removed_resources', '[]'::jsonb
  );
end $$;

-- Safe default: apply only in-place metadata changes and additions. Every removal is detached unless explicitly opted into deletion.
create or replace function public.apply_academic_template_update(requested_template_id uuid, removal_decisions jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare imp public.academic_template_imports%rowtype; current_revision integer; item record; decision text;
begin
  select * into imp from public.academic_template_imports where template_id = requested_template_id and owner_id = auth.uid() for update;
  if imp.id is null then raise exception 'Template is not installed'; end if;
  select revision into current_revision from public.academic_templates where id = requested_template_id for share;
  if current_revision is null then raise exception 'Template no longer exists'; end if;
  -- Only mapped rows are managed. Unmapped student-created rows are never considered.
  for item in select m.* from public.academic_template_entity_mappings m where m.import_id = imp.id and m.detached_at is null loop
    if item.entity_type = 'topic' and not exists (select 1 from public.academic_template_topics t where t.id = item.template_entity_id and not t.archived) then
      decision := coalesce(removal_decisions #>> array['removed_topics', item.template_entity_id::text], 'keep');
      if decision = 'delete' then delete from public.academic_topics where id = item.personal_entity_id and owner_id = auth.uid(); else update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id; update public.academic_topics set origin_template_topic_id = null where id = item.personal_entity_id; end if;
    elsif item.entity_type = 'task_type' and not exists (select 1 from public.academic_template_task_types t where t.id = item.template_entity_id and t.active) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_task_types set origin_template_task_type_id = null where id = item.personal_entity_id;
    elsif item.entity_type = 'subtopic' and not exists (select 1 from public.academic_template_subtopics t where t.id = item.template_entity_id) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_subtopics set origin_template_subtopic_id = null where id = item.personal_entity_id;
    elsif item.entity_type = 'skill_tag' and not exists (select 1 from public.academic_template_skill_tags t where t.id = item.template_entity_id and t.active) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_skill_tags set origin_template_skill_tag_id = null where id = item.personal_entity_id;
    elsif item.entity_type = 'resource' and not exists (select 1 from public.academic_template_resources t where t.id = item.template_entity_id and not t.archived) then
      update public.academic_template_entity_mappings set detached_at = now() where import_id = imp.id and entity_type = item.entity_type and template_entity_id = item.template_entity_id;
      update public.academic_resources set origin_template_resource_id = null where id = item.personal_entity_id;
    end if;
  end loop;
  update public.academic_template_imports set last_synced_revision = current_revision, last_synced_at = now() where id = imp.id;
  return jsonb_build_object('template_id', requested_template_id, 'revision', current_revision);
end $$;

revoke all on function public.touch_academic_template_revision(uuid) from public;
revoke all on function public.preview_academic_template_update(uuid) from public;
revoke all on function public.apply_academic_template_update(uuid, jsonb) from public;
grant execute on function public.touch_academic_template_revision(uuid) to authenticated;
grant execute on function public.preview_academic_template_update(uuid) to authenticated;
grant execute on function public.apply_academic_template_update(uuid, jsonb) to authenticated;

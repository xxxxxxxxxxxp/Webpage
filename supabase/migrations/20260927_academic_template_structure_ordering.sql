-- Additive persistent ordering for the two manually ordered Template collections.
alter table public.academic_template_task_types add column if not exists sort_order integer not null default 0;
alter table public.academic_template_skill_tags add column if not exists sort_order integer not null default 0;

-- Give existing rows deterministic initial positions without changing Topic ordering.
with ranked as (
  select id, row_number() over (partition by subject_id order by name, id) - 1 as position
  from public.academic_template_task_types
)
update public.academic_template_task_types as row set sort_order = ranked.position from ranked where row.id = ranked.id and row.sort_order = 0;

with ranked as (
  select id, row_number() over (partition by subject_id order by name, id) - 1 as position
  from public.academic_template_skill_tags
)
update public.academic_template_skill_tags as row set sort_order = ranked.position from ranked where row.id = ranked.id and row.sort_order = 0;

create index if not exists academic_template_task_types_subject_sort_idx on public.academic_template_task_types(subject_id, sort_order, name);
create index if not exists academic_template_skill_tags_subject_sort_idx on public.academic_template_skill_tags(subject_id, sort_order, name);

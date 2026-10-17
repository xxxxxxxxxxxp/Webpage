-- School-wide resources are separate from Course resources and belong to one School.
create table public.school_resources (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  description text not null default '',
  url text not null default '',
  sort_order integer not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index school_resources_school_sort_idx
  on public.school_resources(school_id, sort_order, lower(title), id);

create or replace function public.set_school_resource_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function public.set_school_resource_updated_at() from public, anon, authenticated;

create trigger set_school_resource_updated_at
before update on public.school_resources
for each row execute function public.set_school_resource_updated_at();

alter table public.school_resources enable row level security;

create policy school_resources_read_authenticated
on public.school_resources
for select
to authenticated
using (true);

create policy school_resources_insert_admin
on public.school_resources
for insert
to authenticated
with check (
  exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  )
);

create policy school_resources_update_admin
on public.school_resources
for update
to authenticated
using (
  exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  )
)
with check (
  exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  )
);

create policy school_resources_delete_admin
on public.school_resources
for delete
to authenticated
using (
  exists (
    select 1 from public.profiles
    where profiles.id = auth.uid() and profiles.role = 'admin'
  )
);

revoke all on public.school_resources from anon;
grant select, insert, update, delete on public.school_resources to authenticated;

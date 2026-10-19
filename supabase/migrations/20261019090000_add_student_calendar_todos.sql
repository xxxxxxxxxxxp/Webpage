-- Student-only Calendar & To-do persistence. Existing course_week_progress
-- remains the source of truth for individual lesson completion.
create table public.course_lesson_due_dates (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.course_enrollments(id) on delete cascade,
  week_number integer not null check (week_number >= 1),
  due_type text not null default 'week' check (due_type in ('week', 'date')),
  due_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enrollment_id, week_number),
  check (
    (due_type = 'week' and due_date is null)
    or (due_type = 'date' and due_date is not null)
  )
);

create table public.student_todos (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  notes text not null default '',
  due_type text not null default 'week' check (due_type in ('week', 'date')),
  due_date date,
  completed boolean not null default false,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (due_type = 'week' and due_date is null)
    or (due_type = 'date' and due_date is not null)
  ),
  check ((completed and completed_at is not null) or (not completed and completed_at is null))
);

create index course_lesson_due_dates_enrollment_week_idx
  on public.course_lesson_due_dates(enrollment_id, week_number);

create index student_todos_student_active_due_idx
  on public.student_todos(student_id, completed, due_date, updated_at desc);

create or replace function public.set_calendar_todo_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function public.set_calendar_todo_updated_at() from public, anon, authenticated;

create trigger set_course_lesson_due_dates_updated_at
before update on public.course_lesson_due_dates
for each row execute function public.set_calendar_todo_updated_at();

create trigger set_student_todos_updated_at
before update on public.student_todos
for each row execute function public.set_calendar_todo_updated_at();

alter table public.course_lesson_due_dates enable row level security;
alter table public.student_todos enable row level security;

create policy course_lesson_due_dates_select_own
on public.course_lesson_due_dates
for select to authenticated
using (
  exists (
    select 1 from public.course_enrollments enrollment
    join public.profiles profile on profile.id = enrollment.student_id
    where enrollment.id = course_lesson_due_dates.enrollment_id
      and enrollment.student_id = auth.uid()
      and profile.role = 'student'
  )
);

create policy course_lesson_due_dates_insert_own
on public.course_lesson_due_dates
for insert to authenticated
with check (
  exists (
    select 1 from public.course_enrollments enrollment
    join public.profiles profile on profile.id = enrollment.student_id
    where enrollment.id = course_lesson_due_dates.enrollment_id
      and enrollment.student_id = auth.uid()
      and profile.role = 'student'
  )
);

create policy course_lesson_due_dates_update_own
on public.course_lesson_due_dates
for update to authenticated
using (
  exists (
    select 1 from public.course_enrollments enrollment
    join public.profiles profile on profile.id = enrollment.student_id
    where enrollment.id = course_lesson_due_dates.enrollment_id
      and enrollment.student_id = auth.uid()
      and profile.role = 'student'
  )
)
with check (
  exists (
    select 1 from public.course_enrollments enrollment
    join public.profiles profile on profile.id = enrollment.student_id
    where enrollment.id = course_lesson_due_dates.enrollment_id
      and enrollment.student_id = auth.uid()
      and profile.role = 'student'
  )
);

create policy course_lesson_due_dates_delete_own
on public.course_lesson_due_dates
for delete to authenticated
using (
  exists (
    select 1 from public.course_enrollments enrollment
    join public.profiles profile on profile.id = enrollment.student_id
    where enrollment.id = course_lesson_due_dates.enrollment_id
      and enrollment.student_id = auth.uid()
      and profile.role = 'student'
  )
);

create policy student_todos_select_own
on public.student_todos
for select to authenticated
using (
  student_id = auth.uid()
  and exists (
    select 1 from public.profiles profile
    where profile.id = auth.uid() and profile.role = 'student'
  )
);

create policy student_todos_insert_own
on public.student_todos
for insert to authenticated
with check (
  student_id = auth.uid()
  and exists (
    select 1 from public.profiles profile
    where profile.id = auth.uid() and profile.role = 'student'
  )
);

create policy student_todos_update_own
on public.student_todos
for update to authenticated
using (
  student_id = auth.uid()
  and exists (
    select 1 from public.profiles profile
    where profile.id = auth.uid() and profile.role = 'student'
  )
)
with check (
  student_id = auth.uid()
  and exists (
    select 1 from public.profiles profile
    where profile.id = auth.uid() and profile.role = 'student'
  )
);

create policy student_todos_delete_own
on public.student_todos
for delete to authenticated
using (
  student_id = auth.uid()
  and exists (
    select 1 from public.profiles profile
    where profile.id = auth.uid() and profile.role = 'student'
  )
);

revoke all on public.course_lesson_due_dates, public.student_todos from anon;
grant select, insert, update, delete on public.course_lesson_due_dates, public.student_todos to authenticated;

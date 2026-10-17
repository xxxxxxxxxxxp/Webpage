alter table public.books
  add column if not exists recommended boolean not null default false;

comment on column public.books.recommended is
  'Whether the book is recommended within its assigned reading level.';

-- O mínimo do Supabase para rodar as migrações da Central num Postgres local de teste.
-- auth.uid() e auth.jwt() leem a sessão simulada em request.jwt.claims, como no Supabase.
create role anon nologin;
create role authenticated nologin;
create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt()->>'sub', '')::uuid $$;
grant execute on all functions in schema auth to anon, authenticated;
grant usage on schema public to anon, authenticated;
create publication supabase_realtime;
-- Storage (só o que a migração 010 usa)
create schema storage;
grant usage on schema storage to anon, authenticated;
create table storage.buckets (id text primary key, name text not null, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid default auth.uid());
alter table storage.objects enable row level security;
grant select, insert on storage.objects to authenticated;

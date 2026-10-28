-- Central de Organização: dados do app de tarefas e projetos (tabelas novas, prefixo central_)
create schema if not exists central_priv;
revoke all on schema central_priv from public, anon;
grant usage on schema central_priv to authenticated;

-- Quem pode entrar além do domínio da empresa
create table public.central_membros (
  email text primary key check (email = lower(email)),
  papel text not null default 'membro' check (papel in ('admin','membro')),
  criado_em timestamptz not null default now()
);
alter table public.central_membros enable row level security;

create or replace function central_priv.e_membro() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select auth.jwt()->>'email') like '%@vitapowernutrition.com.br'
    or exists (select 1 from public.central_membros m where m.email = lower((select auth.jwt()->>'email'))),
    false)
$$;
revoke all on function central_priv.e_membro() from public, anon;
grant execute on function central_priv.e_membro() to authenticated;

create policy "membros veem a lista" on public.central_membros for select to authenticated
  using ((select central_priv.e_membro()));

-- Nome de cada pessoa do time
create table public.central_perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null default '',
  email text not null default '',
  atualizado_em timestamptz not null default now()
);
alter table public.central_perfis enable row level security;
create policy "membros veem perfis" on public.central_perfis for select to authenticated
  using ((select central_priv.e_membro()));
create policy "cada um cria o seu" on public.central_perfis for insert to authenticated
  with check (id = (select auth.uid()) and (select central_priv.e_membro()));
create policy "cada um edita o seu" on public.central_perfis for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Documentos do app: tarefas, projetos, paginas, config (time) e pessoal:<uid> (só o dono)
create table public.central_docs (
  colecao text not null,
  doc_id text not null,
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid(),
  primary key (colecao, doc_id),
  check (colecao in ('tarefas','projetos','paginas','config') or colecao ~ '^pessoal:[0-9a-f-]{36}$')
);
alter table public.central_docs enable row level security;

create or replace function central_priv.pode_ver(c text) returns boolean
language sql stable set search_path = '' as $$
  select case when c like 'pessoal:%' then c = 'pessoal:' || (select auth.uid())::text
              else (select central_priv.e_membro()) end
$$;
grant execute on function central_priv.pode_ver(text) to authenticated;

create policy "ler" on public.central_docs for select to authenticated using (central_priv.pode_ver(colecao));
create policy "criar" on public.central_docs for insert to authenticated with check (central_priv.pode_ver(colecao));
create policy "editar" on public.central_docs for update to authenticated
  using (central_priv.pode_ver(colecao)) with check (central_priv.pode_ver(colecao));
create policy "excluir" on public.central_docs for delete to authenticated using (central_priv.pode_ver(colecao));

create or replace function central_priv.carimbar() returns trigger
language plpgsql set search_path = '' as $$
begin new.atualizado_em := now(); new.atualizado_por := auth.uid(); return new; end $$;
create trigger central_docs_carimbo before insert or update on public.central_docs
  for each row execute function central_priv.carimbar();

revoke all on public.central_docs, public.central_perfis, public.central_membros from anon;
grant select, insert, update, delete on public.central_docs to authenticated;
grant select, insert, update on public.central_perfis to authenticated;
grant select on public.central_membros to authenticated;

alter publication supabase_realtime add table public.central_docs, public.central_perfis;

insert into public.central_membros (email, papel) values ('andrew@vitapowernutrition.com.br', 'admin');

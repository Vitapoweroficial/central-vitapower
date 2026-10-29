-- Histórico de versões e lixeira da Central.
-- Toda criação, alteração e exclusão em central_docs vira uma linha aqui, gravada pelo próprio banco (trigger),
-- então nada depende da tela estar aberta nem do app lembrar de registrar.
-- Só acrescenta: não altera nem apaga nenhum dado existente.

create table public.central_docs_historico (
  id bigint generated always as identity primary key,
  colecao text not null,
  doc_id text not null,
  operacao text not null check (operacao in ('criar','editar','excluir')),
  dados jsonb,                  -- como o item ficou depois da operação; na exclusão, como estava antes de sair
  em timestamptz not null default now(),
  por uuid                      -- quem fez (auth.uid()); vazio quando gravado pelo conector do Claude
);
create index central_docs_historico_doc on public.central_docs_historico (colecao, doc_id, id desc);
create index central_docs_historico_excl on public.central_docs_historico (doc_id, id desc) where operacao = 'excluir';
alter table public.central_docs_historico enable row level security;

-- Quem vê o item vê o histórico dele (mesma regra de central_docs). Ninguém escreve direto: só o trigger.
create policy "ler" on public.central_docs_historico for select to authenticated
  using (central_priv.pode_ver(colecao));
revoke all on public.central_docs_historico from anon, authenticated;
grant select on public.central_docs_historico to authenticated;

create or replace function central_priv.registrar_historico() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por)
    values (old.colecao, old.doc_id, 'excluir', old.dados, auth.uid());
    return old;
  end if;
  if tg_op = 'UPDATE' and new.dados is not distinct from old.dados then
    return new; -- regravou igual: não é versão nova
  end if;
  insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por)
  values (new.colecao, new.doc_id, case when tg_op = 'INSERT' then 'criar' else 'editar' end, new.dados, auth.uid());
  return new;
end $$;
revoke all on function central_priv.registrar_historico() from public, anon, authenticated;

create trigger central_docs_historico after insert or update or delete on public.central_docs
  for each row execute function central_priv.registrar_historico();

-- Lixeira: o que foi excluído e não existe mais em nenhuma coleção visível
-- (mover entre Pessoal e Time grava no destino e exclui na origem; isso não conta como exclusão).
create view public.central_lixeira with (security_invoker = true) as
select distinct on (h.doc_id) h.colecao, h.doc_id, h.dados, h.em, h.por
from public.central_docs_historico h
where h.operacao = 'excluir'
  and not exists (select 1 from public.central_docs d where d.doc_id = h.doc_id)
order by h.doc_id, h.id desc;
revoke all on public.central_lixeira from anon, authenticated;
grant select on public.central_lixeira to authenticated;

-- Ponto de partida: a versão atual de cada item vira a primeira linha do histórico
insert into public.central_docs_historico (colecao, doc_id, operacao, dados, em, por)
select colecao, doc_id, 'criar', dados, atualizado_em, atualizado_por from public.central_docs;

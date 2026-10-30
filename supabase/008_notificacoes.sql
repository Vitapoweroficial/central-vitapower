-- Central: notificações e menções (backlog item 11).
-- Cada pessoa recebe um aviso quando:
--   - uma tarefa do time é atribuída a ela;
--   - alguém comenta numa tarefa que ela criou ou pela qual responde;
--   - alguém a menciona com @ num comentário (campo "mencoes" do comentário) ou no texto de uma página
--     (<span data-mencao="id">);
--   - uma tarefa que ela criou é concluída por outra pessoa;
--   - pedem a aprovação dela num documento, ou respondem a uma aprovação que ela pediu;
--   - ela é adicionada a um projeto restrito.
-- Os avisos nascem do histórico (central_docs_historico), comparando a versão nova com a anterior; por isso valem para
-- qualquer caminho de gravação e ninguém recebe aviso do que ele mesmo fez. Itens pessoais não geram avisos, e ninguém
-- recebe aviso de item que não pode ver. Cada pessoa só lê e marca como lidos os próprios avisos.
-- Só acrescenta (tabela, funções e gatilho novos); nada é apagado. Depende de 007_documentos.sql.

create table public.central_notificacoes (
  id bigint generated always as identity primary key,
  usuario uuid not null references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('atribuida','comentario','mencao','concluida','aprovacao','aprovacao_resposta','projeto')),
  colecao text not null,
  doc_id text not null,
  titulo text not null default '',
  trecho text,
  por uuid,
  em timestamptz not null default now(),
  lida_em timestamptz
);
create index central_notificacoes_usuario on public.central_notificacoes (usuario, id desc);
alter table public.central_notificacoes enable row level security;
create policy "ler as minhas" on public.central_notificacoes for select to authenticated using (usuario = (select auth.uid()));
revoke all on public.central_notificacoes from anon, authenticated;
grant select on public.central_notificacoes to authenticated;
alter publication supabase_realtime add table public.central_notificacoes;

-- A pessoa u pode ver este projeto? (mesma regra de papel_projeto, mas para outra pessoa que não a logada)
create or replace function central_priv.ve_projeto_de(p_id text, u uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  with e as (select lower(au.email) as email from auth.users au where au.id = u)
  select exists (select 1 from e where e.email like '%@vitapowernutrition.com.br'
                 or exists (select 1 from public.central_membros m where m.email = e.email))
     and (p_id is null
          or not exists (select 1 from public.central_projetos p where p.id = p_id)
          or exists (select 1 from e join public.central_membros m on m.email = e.email where m.papel = 'admin')
          or exists (select 1 from public.central_projetos p
                     left join public.central_projeto_membros pm on pm.projeto_id = p.id and pm.usuario = u
                     where p.id = p_id and (p.acesso = 'time' or pm.usuario is not null))) $$;
revoke all on function central_priv.ve_projeto_de(text, uuid) from public, anon, authenticated;

create or replace function central_priv.uuid_ou_nulo(t text) returns uuid
language sql immutable set search_path = '' as $$
  select case when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid end $$;
revoke all on function central_priv.uuid_ou_nulo(text) from public, anon, authenticated;

-- Grava um aviso, se fizer sentido: não avisa a própria pessoa, nem quem não vê o item, nem repete o mesmo aviso
create or replace function central_priv.avisar(p_usuario uuid, p_tipo text, p_colecao text, p_doc text, p_titulo text,
  p_trecho text, p_por uuid, p_projeto text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_usuario is null or p_usuario is not distinct from p_por then return; end if;
  if not central_priv.ve_projeto_de(case when p_colecao = 'tarefas' then p_projeto when p_colecao = 'projetos' then p_doc end, p_usuario) then return; end if;
  if exists (select 1 from public.central_notificacoes n where n.usuario = p_usuario and n.colecao = p_colecao and n.doc_id = p_doc
             and n.lida_em is null and n.em > now() - interval '1 second' and (n.tipo = p_tipo or n.tipo = 'mencao')) then
    return; -- mesma gravação: a menção já cobre o comentário
  end if;
  insert into public.central_notificacoes (usuario, tipo, colecao, doc_id, titulo, trecho, por)
  values (p_usuario, p_tipo, p_colecao, p_doc, left(coalesce(p_titulo, ''), 200), left(p_trecho, 280), p_por);
end $$;
revoke all on function central_priv.avisar(uuid, text, text, text, text, text, uuid, text) from public, anon, authenticated;

create or replace function central_priv.notificar() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  antes jsonb; d jsonb := new.dados; por uuid := new.por; c jsonb; a jsonb; o jsonb; u uuid; tit text; proj text; ja uuid[];
begin
  if new.operacao = 'excluir' or d is null or new.colecao not in ('tarefas','paginas','projetos') then return new; end if;
  select h.dados into antes from public.central_docs_historico h
   where h.colecao = new.colecao and h.doc_id = new.doc_id and h.id < new.id and h.operacao <> 'excluir'
   order by h.id desc limit 1;
  antes := coalesce(antes, '{}');

  if new.colecao = 'tarefas' then
    tit := d->>'titulo'; proj := d->>'projetoId';
    -- atribuída
    u := central_priv.uuid_ou_nulo(d->>'respId');
    if u is not null and u is distinct from central_priv.uuid_ou_nulo(antes->>'respId') then
      perform central_priv.avisar(u, 'atribuida', 'tarefas', new.doc_id, tit, null, por, proj);
    end if;
    -- comentários novos: primeiro as menções, depois quem cria e quem responde
    for c in select x from jsonb_array_elements(case when jsonb_typeof(d->'comentarios') = 'array' then d->'comentarios' else '[]' end) x
             where not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(antes->'comentarios') = 'array' then antes->'comentarios' else '[]' end) y
                               where y->>'id' = x->>'id') loop
      ja := '{}';
      if jsonb_typeof(c->'mencoes') = 'array' then
        for u in select distinct central_priv.uuid_ou_nulo(m) from jsonb_array_elements_text(c->'mencoes') m loop
          perform central_priv.avisar(u, 'mencao', 'tarefas', new.doc_id, tit, c->>'texto', por, proj);
          ja := ja || u;
        end loop;
      end if;
      for u in select distinct x from unnest(array[central_priv.uuid_ou_nulo(d->>'respId'), central_priv.uuid_ou_nulo(d->>'criadoPor')]) x loop
        if u is not null and not (u = any(ja)) then
          perform central_priv.avisar(u, 'comentario', 'tarefas', new.doc_id, tit, c->>'texto', por, proj);
        end if;
      end loop;
    end loop;
    -- concluída por outra pessoa
    if d->>'status' = 'feito' and antes->>'status' is distinct from 'feito' and antes <> '{}' then
      perform central_priv.avisar(central_priv.uuid_ou_nulo(d->>'criadoPor'), 'concluida', 'tarefas', new.doc_id, tit, null, por, proj);
    end if;

  elsif new.colecao = 'paginas' then
    tit := d->>'titulo';
    -- pedidos de aprovação novos e respostas
    for a in select x from jsonb_array_elements(case when jsonb_typeof(d->'aprovacoes') = 'array' then d->'aprovacoes' else '[]' end) x loop
      o := (select y from jsonb_array_elements(case when jsonb_typeof(antes->'aprovacoes') = 'array' then antes->'aprovacoes' else '[]' end) y
            where y->>'id' = a->>'id');
      if o is null and coalesce(a->>'status', 'pendente') = 'pendente' then
        perform central_priv.avisar(central_priv.uuid_ou_nulo(a->>'por'), 'aprovacao', 'paginas', new.doc_id, tit, null, por, null);
      elsif o is not null and coalesce(a->>'status', 'pendente') <> 'pendente' and a->>'status' is distinct from o->>'status' then
        perform central_priv.avisar(central_priv.uuid_ou_nulo(a->>'pedidoPor'), 'aprovacao_resposta', 'paginas', new.doc_id, tit,
          case when a->>'status' = 'aprovado' then 'aprovou' else 'pediu ajustes' end, por, null);
      end if;
    end loop;
    -- menções novas no texto
    for u in select distinct central_priv.uuid_ou_nulo(m[1]) from regexp_matches(coalesce(d->>'conteudo', ''), 'data-mencao="([0-9a-fA-F-]{36})"', 'g') m
             except select central_priv.uuid_ou_nulo(m[1]) from regexp_matches(coalesce(antes->>'conteudo', ''), 'data-mencao="([0-9a-fA-F-]{36})"', 'g') m loop
      perform central_priv.avisar(u, 'mencao', 'paginas', new.doc_id, tit, null, por, null);
    end loop;

  else -- projetos: quem entrou na lista de pessoas
    tit := d->>'nome';
    for u in select central_priv.uuid_ou_nulo(m->>'id') from jsonb_array_elements(case when jsonb_typeof(d->'membros') = 'array' then d->'membros' else '[]' end) m
             except select central_priv.uuid_ou_nulo(m->>'id') from jsonb_array_elements(case when jsonb_typeof(antes->'membros') = 'array' then antes->'membros' else '[]' end) m loop
      perform central_priv.avisar(u, 'projeto', 'projetos', new.doc_id, tit, null, por, null);
    end loop;
  end if;
  return new;
end $$;
revoke all on function central_priv.notificar() from public, anon, authenticated;
create trigger central_notificar after insert on public.central_docs_historico
  for each row execute function central_priv.notificar();

-- Marca como lidos (todos, ou só os ids passados) os avisos de quem está logado
create or replace function public.central_marcar_lidas(p_ids bigint[] default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  update public.central_notificacoes set lida_em = now()
   where usuario = auth.uid() and lida_em is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.central_marcar_lidas(bigint[]) from public, anon;
grant execute on function public.central_marcar_lidas(bigint[]) to authenticated;

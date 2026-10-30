-- Central: controle de edição simultânea (backlog item 3).
-- Cada projeto, tarefa, página e configuração ganha um número de versão que sobe a cada alteração real.
-- O app recebe esse número junto com o item (campo "_versao") e o devolve ao salvar. Se outra pessoa salvou
-- o mesmo item no meio-tempo, a gravação é recusada com o erro CV409 em vez de apagar a mudança dela; o app então
-- pergunta se a pessoa quer manter a versão do colega ou salvar a sua por cima (a outra continua no histórico).
-- Gravação sem "_versao" (item novo, restauração da lixeira ou de uma versão antiga) continua aceita como antes.
-- Nada é apagado. Depende de 004_relacional.sql.

alter table public.central_projetos add column versao bigint not null default 1;
alter table public.central_tarefas add column versao bigint not null default 1;
alter table public.central_paginas add column versao bigint not null default 1;
alter table public.central_config add column versao bigint not null default 1;

-- A versão só sobe quando o conteúdo muda (salvar sem mudar nada não gera conflito para os outros)
create or replace function central_priv.subir_versao() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (to_jsonb(new) - array['versao','gravado_em','gravado_por']) is distinct from (to_jsonb(old) - array['versao','gravado_em','gravado_por']) then
    new.versao := old.versao + 1;
  else
    new.versao := old.versao;
  end if;
  return new;
end $$;
revoke all on function central_priv.subir_versao() from public, anon, authenticated;
create trigger central_versao before update on public.central_projetos for each row execute function central_priv.subir_versao();
create trigger central_versao before update on public.central_tarefas for each row execute function central_priv.subir_versao();
create trigger central_versao before update on public.central_paginas for each row execute function central_priv.subir_versao();
create trigger central_versao before update on public.central_config for each row execute function central_priv.subir_versao();

-- O JSON de cada item passa a levar "_versao"
create or replace function central_priv.doc_projeto(p public.central_projetos) returns jsonb
language sql stable set search_path = '' as $$
  select p.extras || central_priv.sem_nulos(jsonb_build_object(
    'nome', p.nome, 'descricao', p.descricao, 'inicio', central_priv.dia(p.inicio), 'prazo', central_priv.dia(p.prazo),
    'status', p.status, 'cor', p.cor, 'checklist', p.checklist,
    'criadoEm', central_priv.iso(p.criado_em), 'criadoPor', p.criado_por, 'atualizadoEm', central_priv.iso(p.atualizado_em),
    '_versao', p.versao))
$$;
create or replace function central_priv.doc_tarefa(t public.central_tarefas) returns jsonb
language sql stable set search_path = '' as $$
  select t.extras || central_priv.sem_nulos(jsonb_build_object(
    'tipo', 'tarefa', 'titulo', t.titulo, 'descricao', t.descricao, 'status', t.status, 'prioridade', t.prioridade,
    'inicio', central_priv.dia(t.inicio), 'prazo', central_priv.dia(t.prazo), 'foco', central_priv.dia(t.foco),
    'aguardando', t.aguardando, 'respId', t.resp_id, 'respNome', t.resp_nome, 'projetoId', t.projeto_id, 'paiId', t.pai_id,
    'recorrencia', t.recorrencia, 'proxGerada', t.prox_gerada, 'arquivado', t.arquivado, 'ordem', t.ordem,
    'checklist', t.checklist, 'links', t.links, 'campos', t.campos, 'historico', t.historico,
    'dependeDe', (select jsonb_agg(d.depende_de order by d.ordem) from public.central_dependencias d where d.tarefa_id = t.id),
    'comentarios', (select jsonb_agg(c.extras || central_priv.sem_nulos(jsonb_build_object('id', c.id, 'por', c.por, 'texto', c.texto, 'em', central_priv.iso(c.em))) order by c.ordem)
                    from public.central_comentarios c where c.tarefa_id = t.id),
    'criadoEm', central_priv.iso(t.criado_em), 'criadoPor', t.criado_por, 'concluidoEm', central_priv.iso(t.concluido_em),
    'atualizadoEm', central_priv.iso(t.atualizado_em), '_versao', t.versao))
$$;
create or replace function central_priv.doc_pagina(p public.central_paginas) returns jsonb
language sql stable set search_path = '' as $$
  select p.extras || central_priv.sem_nulos(jsonb_build_object(
    'tipo', 'pagina', 'titulo', p.titulo, 'icone', p.icone, 'parentId', p.parent_id, 'conteudo', p.conteudo, 'ordem', p.ordem,
    'criadoEm', central_priv.iso(p.criado_em), 'criadoPor', p.criado_por, 'editadoPor', p.editado_por,
    'atualizadoEm', central_priv.iso(p.atualizado_em), '_versao', p.versao))
$$;
create or replace view public.central_itens with (security_invoker = true) as
  select 'projetos'::text as colecao, p.id as doc_id, central_priv.doc_projeto(p) as dados, p.gravado_em as atualizado_em, p.gravado_por as atualizado_por
  from public.central_projetos p where p.excluido_em is null
  union all
  select case when t.privada then 'pessoal:' || t.dono::text else 'tarefas' end, t.id, central_priv.doc_tarefa(t), t.gravado_em, t.gravado_por
  from public.central_tarefas t where t.excluido_em is null
  union all
  select case when g.privada then 'pessoal:' || g.dono::text else 'paginas' end, g.id, central_priv.doc_pagina(g), g.gravado_em, g.gravado_por
  from public.central_paginas g where g.excluido_em is null
  union all
  select 'config', c.chave, central_priv.sem_nulos(c.valor) || jsonb_build_object('_versao', c.versao), c.gravado_em, c.gravado_por
  from public.central_config c where c.excluido_em is null;

-- Segura a linha do item até o fim da gravação, para duas gravações ao mesmo tempo não passarem as duas pela conferência
create or replace function central_priv.travar(p_colecao text, p_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_colecao = 'projetos' then perform 1 from public.central_projetos where id = p_id for update;
  elsif p_colecao = 'config' then perform 1 from public.central_config where chave = p_id for update;
  else
    perform 1 from public.central_tarefas where id = p_id for update;
    perform 1 from public.central_paginas where id = p_id for update;
  end if;
end $$;
revoke all on function central_priv.travar(text, text) from public, anon, authenticated;

create or replace function public.central_gravar(p_colecao text, p_id text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare antes jsonb; depois jsonb; por uuid := auth.uid(); quem uuid;
begin
  if not (central_priv.e_servidor() or (por is not null and central_priv.pode_ver(p_colecao))) then
    raise exception 'sem permissão para gravar em %', p_colecao using errcode = '42501';
  end if;
  if not (p_colecao in ('tarefas','projetos','paginas','config') or p_colecao ~ '^pessoal:[0-9a-f-]{36}$') then
    raise exception 'coleção desconhecida: %', p_colecao using errcode = '22023';
  end if;
  if exists (select 1 from public.central_tarefas t where t.id = p_id and t.excluido_em is null and t.privada and t.dono is distinct from por and not central_priv.e_servidor())
     or exists (select 1 from public.central_paginas g where g.id = p_id and g.excluido_em is null and g.privada and g.dono is distinct from por and not central_priv.e_servidor()) then
    raise exception 'sem permissão para alterar este item' using errcode = '42501';
  end if;
  if p_dados ? '_versao' and jsonb_typeof(p_dados->'_versao') not in ('number','null') then
    raise exception 'campo _versao deve ser número' using errcode = '22023';
  end if;
  perform central_priv.travar(p_colecao, p_id);
  antes := central_priv.doc_atual(p_colecao, p_id);
  -- outra pessoa salvou depois que este app leu o item: recusa e diz qual é a versão atual e quem salvou
  if antes is not null and jsonb_typeof(p_dados->'_versao') = 'number' and (p_dados->>'_versao')::numeric <> (antes->>'_versao')::numeric then
    select atualizado_por into quem from public.central_itens where colecao = p_colecao and doc_id = p_id;
    raise exception 'conflito:%:%', antes->>'_versao', coalesce(quem::text, '') using errcode = 'CV409',
      hint = 'Outra pessoa salvou este item enquanto você editava.';
  end if;
  perform central_priv.decompor(p_colecao, p_id, p_dados - '_versao', por);
  depois := central_priv.doc_atual(p_colecao, p_id);
  if (antes - '_versao') is distinct from (depois - '_versao') then
    insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por)
    values (p_colecao, p_id, case when antes is null then 'criar' else 'editar' end, depois - '_versao', por);
  end if;
  return depois;
end $$;

create or replace function public.central_excluir(p_colecao text, p_id text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare antes jsonb; por uuid := auth.uid();
begin
  if not (central_priv.e_servidor() or (por is not null and central_priv.pode_ver(p_colecao))) then
    raise exception 'sem permissão para excluir em %', p_colecao using errcode = '42501';
  end if;
  antes := central_priv.marcar_excluido(p_colecao, p_id, por);
  if antes is null then return false; end if;
  insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por) values (p_colecao, p_id, 'excluir', antes - '_versao', por);
  return true;
end $$;
revoke all on function public.central_gravar(text, text, jsonb), public.central_excluir(text, text) from public, anon;
grant execute on function public.central_gravar(text, text, jsonb), public.central_excluir(text, text) to authenticated;

-- A conferência com central_docs ignora o número de versão
create or replace function central_priv.conferir_copia() returns table (colecao text, doc_id text, problema text)
language sql stable security definer set search_path = '' as $$
  select coalesce(d.colecao, i.colecao), coalesce(d.doc_id, i.doc_id),
         case when i.doc_id is null then 'faltou na cópia' when d.doc_id is null then 'sobrou na cópia' else 'conteúdo diferente' end
  from public.central_docs d
  full join public.central_itens i on i.colecao = d.colecao and i.doc_id = d.doc_id
  where i.doc_id is null or d.doc_id is null or central_priv.normalizar(d.colecao, d.dados) <> (i.dados - '_versao')
$$;
revoke all on function central_priv.conferir_copia() from public, anon, authenticated;

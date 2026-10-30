-- Central: permissões por projeto (backlog item 5).
-- Cada projeto pode ser aberto a todo o time (como sempre foi) ou restrito a pessoas escolhidas, cada uma com um papel:
--   dono   – vê, edita, decide quem tem acesso e é o único (com os administradores) que exclui o projeto;
--   editor – vê e edita o projeto e as tarefas dele;
--   leitor – só vê.
-- Em projeto aberto ao time, todo membro é editor, salvo papel dado a ele na lista. Administradores são dono de tudo.
-- Quem não tem acesso não vê o projeto, as tarefas dele, os comentários nem o histórico, nem pela API direta.
-- O item chega ao app com "acesso" (só quando restrito), "membros" e "_papel" (o papel de quem está vendo).
-- Nada é apagado: todo projeto existente continua aberto ao time. Depende de 005_concorrencia.sql.

alter table public.central_projetos add column acesso text not null default 'time' check (acesso in ('time','restrito'));

create table public.central_projeto_membros (
  projeto_id text not null references public.central_projetos(id) on delete cascade,
  usuario uuid not null references auth.users(id) on delete cascade,
  papel text not null check (papel in ('dono','editor','leitor')),
  primary key (projeto_id, usuario)
);
create index central_projeto_membros_usuario on public.central_projeto_membros (usuario);

create or replace function central_priv.e_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.central_membros m where m.email = lower((select auth.jwt()->>'email')) and m.papel = 'admin') $$;
revoke all on function central_priv.e_admin() from public, anon;
grant execute on function central_priv.e_admin() to authenticated;

-- Papel de quem está logado no projeto (null = sem acesso). Tarefa sem projeto conta como projeto aberto.
create or replace function central_priv.papel_projeto(p_id text) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when central_priv.e_servidor() then 'dono'
    when not (select central_priv.e_membro()) then null
    when p_id is null or not exists (select 1 from public.central_projetos p where p.id = p_id) then 'editor'
    when (select central_priv.e_admin()) then 'dono'
    else (select coalesce(m.papel, case when p.acesso = 'time' then 'editor' end)
          from public.central_projetos p
          left join public.central_projeto_membros m on m.projeto_id = p.id and m.usuario = (select auth.uid())
          where p.id = p_id)
  end $$;
revoke all on function central_priv.papel_projeto(text) from public, anon;
grant execute on function central_priv.papel_projeto(text) to authenticated;

create or replace function central_priv.ve_tarefa(privada boolean, dono uuid, projeto_id text) returns boolean
language sql stable set search_path = '' as $$
  select case when privada then dono = (select auth.uid())
              else (select central_priv.e_membro()) and central_priv.papel_projeto(projeto_id) is not null end $$;
grant execute on function central_priv.ve_tarefa(boolean, uuid, text) to authenticated;

-- Histórico e lixeira seguem o acesso atual do item
create or replace function central_priv.ve_historico(p_colecao text, p_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_colecao = 'projetos' then central_priv.papel_projeto(p_id) is not null
    when p_colecao = 'tarefas' then coalesce((select central_priv.papel_projeto(t.projeto_id) is not null from public.central_tarefas t where t.id = p_id), true)
    else true end $$;
revoke all on function central_priv.ve_historico(text, text) from public, anon;
grant execute on function central_priv.ve_historico(text, text) to authenticated;

alter policy "ler" on public.central_projetos
  using (central_priv.papel_projeto(id) is not null);
alter policy "ler" on public.central_tarefas
  using (central_priv.ve_tarefa(privada, dono, projeto_id));
alter policy "ler" on public.central_dependencias
  using (exists (select 1 from public.central_tarefas t where t.id = tarefa_id and central_priv.ve_tarefa(t.privada, t.dono, t.projeto_id)));
alter policy "ler" on public.central_comentarios
  using (exists (select 1 from public.central_tarefas t where t.id = tarefa_id and central_priv.ve_tarefa(t.privada, t.dono, t.projeto_id)));
alter policy "ler" on public.central_docs_historico
  using (central_priv.pode_ver(colecao) and central_priv.ve_historico(colecao, doc_id));

alter table public.central_projeto_membros enable row level security;
create policy "ler" on public.central_projeto_membros for select to authenticated using (central_priv.papel_projeto(projeto_id) is not null);
revoke all on public.central_projeto_membros from anon, authenticated;
grant select on public.central_projeto_membros to authenticated;
alter publication supabase_realtime add table public.central_projeto_membros;

-- O projeto passa a levar quem tem acesso e o papel de quem está vendo
create or replace function central_priv.membros_projeto(p_id text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_agg(jsonb_build_object('id', m.usuario::text, 'papel', m.papel) order by m.usuario)
  from public.central_projeto_membros m where m.projeto_id = p_id $$;
revoke all on function central_priv.membros_projeto(text) from public, anon, authenticated;
create or replace function central_priv.doc_projeto(p public.central_projetos) returns jsonb
language sql stable security definer set search_path = '' as $$
  select p.extras || central_priv.sem_nulos(jsonb_build_object(
    'nome', p.nome, 'descricao', p.descricao, 'inicio', central_priv.dia(p.inicio), 'prazo', central_priv.dia(p.prazo),
    'status', p.status, 'cor', p.cor, 'checklist', p.checklist,
    'criadoEm', central_priv.iso(p.criado_em), 'criadoPor', p.criado_por, 'atualizadoEm', central_priv.iso(p.atualizado_em),
    'acesso', nullif(p.acesso, 'time'), 'membros', central_priv.membros_projeto(p.id),
    '_versao', p.versao, '_papel', central_priv.papel_projeto(p.id)))
$$;

-- Campos calculados que nunca são gravados nem vão para o histórico
create or replace function central_priv.sem_meta(d jsonb) returns jsonb
language sql immutable set search_path = '' as $$ select d - '_versao' - '_papel' $$;

create or replace function central_priv.validar_membros(m jsonb) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if m is null or jsonb_typeof(m) = 'null' then return; end if;
  if jsonb_typeof(m) <> 'array' or exists (select 1 from jsonb_array_elements(m) e
       where jsonb_typeof(e) <> 'object' or coalesce(e->>'id', '') !~ '^[0-9a-f-]{36}$' or coalesce(e->>'papel', '') not in ('dono','editor','leitor')) then
    raise exception 'membros deve ser uma lista de {id, papel} com papel dono, editor ou leitor' using errcode = '22023';
  end if;
end $$;

create or replace function public.central_gravar(p_colecao text, p_id text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  antes jsonb; depois jsonb; por uuid := auth.uid(); quem uuid; servidor boolean := central_priv.e_servidor();
  e_tarefa boolean := p_colecao = 'tarefas' or (p_colecao like 'pessoal:%' and p_dados->>'tipo' = 'tarefa');
  meu_papel text; novo boolean; acesso_atual text; membros_atual jsonb; acesso_pedido text; membros_pedido jsonb;
begin
  if not (servidor or (por is not null and central_priv.pode_ver(p_colecao))) then
    raise exception 'sem permissão para gravar em %', p_colecao using errcode = '42501';
  end if;
  if not (p_colecao in ('tarefas','projetos','paginas','config') or p_colecao ~ '^pessoal:[0-9a-f-]{36}$') then
    raise exception 'coleção desconhecida: %', p_colecao using errcode = '22023';
  end if;
  if exists (select 1 from public.central_tarefas t where t.id = p_id and t.excluido_em is null and t.privada and t.dono is distinct from por and not servidor)
     or exists (select 1 from public.central_paginas g where g.id = p_id and g.excluido_em is null and g.privada and g.dono is distinct from por and not servidor) then
    raise exception 'sem permissão para alterar este item' using errcode = '42501';
  end if;
  if p_dados ? '_versao' and jsonb_typeof(p_dados->'_versao') not in ('number','null') then
    raise exception 'campo _versao deve ser número' using errcode = '22023';
  end if;
  perform central_priv.travar(p_colecao, p_id);

  -- papel no projeto
  if p_colecao = 'projetos' then
    novo := not exists (select 1 from public.central_projetos where id = p_id);
    meu_papel := case when novo then 'dono' else central_priv.papel_projeto(p_id) end;
    if meu_papel is null or meu_papel = 'leitor' then raise exception 'sem permissão para alterar este projeto' using errcode = '42501'; end if;
    perform central_priv.validar_membros(p_dados->'membros');
    if p_dados ? 'acesso' and coalesce(p_dados->>'acesso', 'time') not in ('time','restrito') then
      raise exception 'acesso deve ser time ou restrito' using errcode = '22023';
    end if;
    select acesso into acesso_atual from public.central_projetos where id = p_id;
    membros_atual := coalesce(central_priv.membros_projeto(p_id), '[]');
    acesso_pedido := case when p_dados ? 'acesso' then coalesce(p_dados->>'acesso', 'time') else coalesce(acesso_atual, 'time') end;
    membros_pedido := case when p_dados ? 'membros' then coalesce((select jsonb_agg(jsonb_build_object('id', e->>'id', 'papel', e->>'papel') order by e->>'id')
                                                                    from jsonb_array_elements(nullif(p_dados->'membros', 'null')) e), '[]')
                           else membros_atual end;
    if not novo and meu_papel <> 'dono' and (acesso_pedido is distinct from acesso_atual or membros_pedido is distinct from membros_atual) then
      raise exception 'só o dono do projeto muda quem tem acesso' using errcode = '42501';
    end if;
  elsif e_tarefa and not servidor then
    if coalesce(central_priv.papel_projeto((select projeto_id from public.central_tarefas where id = p_id)), 'leitor') not in ('dono','editor')
       or coalesce(central_priv.papel_projeto(p_dados->>'projetoId'), 'leitor') not in ('dono','editor') then
      raise exception 'sem permissão para alterar tarefas deste projeto' using errcode = '42501';
    end if;
  end if;

  antes := central_priv.doc_atual(p_colecao, p_id);
  if antes is not null and jsonb_typeof(p_dados->'_versao') = 'number' and (p_dados->>'_versao')::numeric <> (antes->>'_versao')::numeric then
    select atualizado_por into quem from public.central_itens where colecao = p_colecao and doc_id = p_id;
    raise exception 'conflito:%:%', antes->>'_versao', coalesce(quem::text, '') using errcode = 'CV409',
      hint = 'Outra pessoa salvou este item enquanto você editava.';
  end if;

  perform central_priv.decompor(p_colecao, p_id, central_priv.sem_meta(p_dados) - 'acesso' - 'membros', por);

  if p_colecao = 'projetos' then
    update public.central_projetos set acesso = acesso_pedido where id = p_id and acesso is distinct from acesso_pedido;
    if membros_pedido is distinct from membros_atual then
      delete from public.central_projeto_membros where projeto_id = p_id;
      insert into public.central_projeto_membros (projeto_id, usuario, papel)
      select p_id, (e->>'id')::uuid, e->>'papel' from jsonb_array_elements(membros_pedido) e;
    end if;
    -- quem cria o projeto é dono dele
    if novo and por is not null then
      insert into public.central_projeto_membros (projeto_id, usuario, papel) values (p_id, por, 'dono')
      on conflict (projeto_id, usuario) do update set papel = 'dono';
    end if;
    if acesso_pedido = 'restrito' and not exists (select 1 from public.central_projeto_membros where projeto_id = p_id and papel = 'dono') then
      raise exception 'projeto restrito precisa de pelo menos um dono' using errcode = '22023';
    end if;
  end if;

  depois := central_priv.doc_atual(p_colecao, p_id);
  if central_priv.sem_meta(antes) is distinct from central_priv.sem_meta(depois) then
    insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por)
    values (p_colecao, p_id, case when antes is null then 'criar' else 'editar' end, central_priv.sem_meta(depois), por);
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
  if not central_priv.e_servidor() then
    -- projeto que ainda não tem dono (criado antes das permissões) segue podendo ser excluído por quem o edita
    if p_colecao = 'projetos' and exists (select 1 from public.central_projetos where id = p_id)
       and central_priv.papel_projeto(p_id) is distinct from 'dono'
       and not (central_priv.papel_projeto(p_id) = 'editor'
                and not exists (select 1 from public.central_projeto_membros m where m.projeto_id = p_id and m.papel = 'dono')) then
      raise exception 'só o dono do projeto pode excluí-lo' using errcode = '42501';
    end if;
    if exists (select 1 from public.central_tarefas t where t.id = p_id and not t.privada
               and coalesce(central_priv.papel_projeto(t.projeto_id), 'leitor') not in ('dono','editor')) then
      raise exception 'sem permissão para excluir tarefas deste projeto' using errcode = '42501';
    end if;
  end if;
  antes := central_priv.marcar_excluido(p_colecao, p_id, por);
  if antes is null then return false; end if;
  insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por) values (p_colecao, p_id, 'excluir', central_priv.sem_meta(antes), por);
  return true;
end $$;
revoke all on function public.central_gravar(text, text, jsonb), public.central_excluir(text, text) from public, anon;
grant execute on function public.central_gravar(text, text, jsonb), public.central_excluir(text, text) to authenticated;

create or replace function central_priv.conferir_copia() returns table (colecao text, doc_id text, problema text)
language sql stable security definer set search_path = '' as $$
  select coalesce(d.colecao, i.colecao), coalesce(d.doc_id, i.doc_id),
         case when i.doc_id is null then 'faltou na cópia' when d.doc_id is null then 'sobrou na cópia' else 'conteúdo diferente' end
  from public.central_docs d
  full join public.central_itens i on i.colecao = d.colecao and i.doc_id = d.doc_id
  where i.doc_id is null or d.doc_id is null
     or central_priv.normalizar(d.colecao, d.dados) <> (central_priv.sem_meta(i.dados) - 'membros')
$$;
revoke all on function central_priv.conferir_copia() from public, anon, authenticated;

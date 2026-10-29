-- Central: modelo relacional (Fase 1, etapa 1).
-- Cria as tabelas de projetos, tarefas, dependências, comentários, páginas e configuração, ao lado de central_docs.
-- Nada é apagado: central_docs continua existindo e sendo usada pelo app até a troca (etapa 2).
--
-- Como fica:
--   - leitura: a visão central_itens monta cada registro no mesmo formato JSON que o app usa hoje (colecao, doc_id, dados),
--     a partir das tabelas; as permissões vêm das políticas RLS das tabelas;
--   - gravação: só pelas funções central_gravar(colecao, doc_id, dados) e central_excluir(colecao, doc_id), que validam
--     a entrada, conferem a permissão, gravam o histórico e fazem exclusão lógica (excluido_em), sem perder relações;
--   - campos que o app grave e que ainda não têm coluna ficam em "extras", para nada se perder.
-- Depende de 001_central.sql e 003_historico.sql.

/* ---------- tabelas ---------- */
create table public.central_projetos (
  id text primary key check (id <> ''),
  nome text not null default '',
  descricao text,
  inicio date,
  prazo date,
  status text not null default 'ativo' check (status in ('ativo','pausado','concluido')),
  cor text,
  checklist jsonb check (checklist is null or jsonb_typeof(checklist) = 'array'),
  criado_em timestamptz,
  criado_por text,
  atualizado_em timestamptz,
  extras jsonb not null default '{}'::jsonb,
  gravado_em timestamptz not null default now(),
  gravado_por uuid,
  excluido_em timestamptz
);

create table public.central_tarefas (
  id text primary key check (id <> ''),
  numero bigint generated always as identity unique,  -- identificador curto e permanente (ex.: #12)
  privada boolean not null default false,
  dono uuid references auth.users(id),                 -- obrigatório quando privada
  titulo text not null default '',
  descricao text,
  status text not null default 'afazer' check (status in ('afazer','fazendo','aguardando','feito')),
  prioridade text check (prioridade in ('alta','media','baixa')),
  inicio date,
  prazo date,
  foco date,
  aguardando text,
  resp_id text,             -- id da pessoa no app (perfil); texto porque há ids antigos da versão do Claude
  resp_nome text,
  projeto_id text references public.central_projetos(id) deferrable initially deferred,
  pai_id text references public.central_tarefas(id) deferrable initially deferred,
  recorrencia text check (recorrencia in ('diaria','uteis','semanal','quinzenal','mensal')),
  prox_gerada boolean,
  arquivado boolean,
  ordem numeric,
  checklist jsonb check (checklist is null or jsonb_typeof(checklist) = 'array'),
  links jsonb check (links is null or jsonb_typeof(links) = 'array'),
  campos jsonb check (campos is null or jsonb_typeof(campos) = 'object'),
  historico jsonb check (historico is null or jsonb_typeof(historico) = 'array'),
  criado_em timestamptz,
  criado_por text,
  concluido_em timestamptz,
  atualizado_em timestamptz,
  extras jsonb not null default '{}'::jsonb,
  gravado_em timestamptz not null default now(),
  gravado_por uuid,
  excluido_em timestamptz,
  check (not privada or dono is not null),
  check (pai_id is distinct from id)
);
create index central_tarefas_projeto on public.central_tarefas (projeto_id) where excluido_em is null;
create index central_tarefas_pai on public.central_tarefas (pai_id) where pai_id is not null;
create index central_tarefas_prazo on public.central_tarefas (prazo) where excluido_em is null and status <> 'feito';
create index central_tarefas_dono on public.central_tarefas (dono) where privada;

create table public.central_dependencias (
  tarefa_id text not null references public.central_tarefas(id) on delete cascade deferrable initially deferred,
  depende_de text not null references public.central_tarefas(id) on delete cascade deferrable initially deferred,
  ordem int not null default 0,
  primary key (tarefa_id, depende_de),
  check (tarefa_id <> depende_de)
);
create index central_dependencias_de on public.central_dependencias (depende_de);

create table public.central_comentarios (
  id text not null,
  tarefa_id text not null references public.central_tarefas(id) on delete cascade deferrable initially deferred,
  ordem int not null default 0,
  por text,
  texto text not null default '' check (length(texto) <= 20000),
  em timestamptz,
  extras jsonb not null default '{}'::jsonb,
  primary key (tarefa_id, id)
);

create table public.central_paginas (
  id text primary key check (id <> ''),
  privada boolean not null default false,
  dono uuid references auth.users(id),
  titulo text not null default '',
  icone text,
  parent_id text references public.central_paginas(id) deferrable initially deferred,
  conteudo text,
  ordem numeric,
  criado_em timestamptz,
  criado_por text,
  editado_por text,
  atualizado_em timestamptz,
  extras jsonb not null default '{}'::jsonb,
  gravado_em timestamptz not null default now(),
  gravado_por uuid,
  excluido_em timestamptz,
  check (not privada or dono is not null),
  check (parent_id is distinct from id)
);
create index central_paginas_parent on public.central_paginas (parent_id) where parent_id is not null;

create table public.central_config (
  chave text primary key check (chave <> ''),
  valor jsonb not null default '{}'::jsonb check (jsonb_typeof(valor) = 'object'),
  gravado_em timestamptz not null default now(),
  gravado_por uuid,
  excluido_em timestamptz
);

/* ---------- permissões (leitura direta; gravação só pelas funções) ---------- */
create or replace function central_priv.ve(privada boolean, dono uuid) returns boolean
language sql stable set search_path = '' as $$
  select case when privada then dono = (select auth.uid()) else (select central_priv.e_membro()) end
$$;
grant execute on function central_priv.ve(boolean, uuid) to authenticated;

alter table public.central_projetos enable row level security;
alter table public.central_tarefas enable row level security;
alter table public.central_dependencias enable row level security;
alter table public.central_comentarios enable row level security;
alter table public.central_paginas enable row level security;
alter table public.central_config enable row level security;
create policy "ler" on public.central_projetos for select to authenticated using ((select central_priv.e_membro()));
create policy "ler" on public.central_tarefas for select to authenticated using (central_priv.ve(privada, dono));
create policy "ler" on public.central_dependencias for select to authenticated
  using (exists (select 1 from public.central_tarefas t where t.id = tarefa_id and central_priv.ve(t.privada, t.dono)));
create policy "ler" on public.central_comentarios for select to authenticated
  using (exists (select 1 from public.central_tarefas t where t.id = tarefa_id and central_priv.ve(t.privada, t.dono)));
create policy "ler" on public.central_paginas for select to authenticated using (central_priv.ve(privada, dono));
create policy "ler" on public.central_config for select to authenticated using ((select central_priv.e_membro()));

revoke all on public.central_projetos, public.central_tarefas, public.central_dependencias, public.central_comentarios,
  public.central_paginas, public.central_config from anon, authenticated;
grant select on public.central_projetos, public.central_tarefas, public.central_dependencias, public.central_comentarios,
  public.central_paginas, public.central_config to authenticated;

/* ---------- conversões entre o JSON do app e as colunas ---------- */
create or replace function central_priv.iso(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;
create or replace function central_priv.dia(d date) returns text
language sql immutable set search_path = '' as $$ select to_char(d, 'YYYY-MM-DD') $$;
-- tira do objeto as chaves com valor null (para o app, null e ausente são a mesma coisa)
create or replace function central_priv.sem_nulos(o jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(o) e(k, v) where jsonb_typeof(v) <> 'null' $$;

-- leitores que validam: valor errado vira erro claro em vez de dado corrompido
create or replace function central_priv.txt(d jsonb, k text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if d->k is null or jsonb_typeof(d->k) = 'null' then return null; end if;
  if jsonb_typeof(d->k) <> 'string' then raise exception 'campo % deve ser texto', k using errcode = '22023'; end if;
  return d->>k;
end $$;
create or replace function central_priv.data(d jsonb, k text) returns date
language plpgsql immutable set search_path = '' as $$
declare v text := central_priv.txt(d, k);
begin
  if v is null or v = '' then return null; end if;
  if v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'campo % deve ser data AAAA-MM-DD', k using errcode = '22007'; end if;
  return v::date;
end $$;
create or replace function central_priv.momento(d jsonb, k text) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare v text := central_priv.txt(d, k);
begin
  if v is null or v = '' then return null; end if;
  return v::timestamptz;
exception when others then raise exception 'campo % deve ser data e hora ISO', k using errcode = '22007';
end $$;
create or replace function central_priv.logico(d jsonb, k text) returns boolean
language plpgsql immutable set search_path = '' as $$
begin
  if d->k is null or jsonb_typeof(d->k) = 'null' then return null; end if;
  if jsonb_typeof(d->k) <> 'boolean' then raise exception 'campo % deve ser verdadeiro ou falso', k using errcode = '22023'; end if;
  return (d->k)::boolean;
end $$;
create or replace function central_priv.numero(d jsonb, k text) returns numeric
language plpgsql immutable set search_path = '' as $$
begin
  if d->k is null or jsonb_typeof(d->k) = 'null' then return null; end if;
  if jsonb_typeof(d->k) <> 'number' then raise exception 'campo % deve ser número', k using errcode = '22023'; end if;
  return (d->k)::numeric;
end $$;
create or replace function central_priv.lista(d jsonb, k text) returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  if d->k is null or jsonb_typeof(d->k) = 'null' then return null; end if;
  if jsonb_typeof(d->k) <> 'array' then raise exception 'campo % deve ser lista', k using errcode = '22023'; end if;
  return d->k;
end $$;

-- monta o JSON de cada registro, no formato que o app conhece
create or replace function central_priv.doc_projeto(p public.central_projetos) returns jsonb
language sql stable set search_path = '' as $$
  select p.extras || central_priv.sem_nulos(jsonb_build_object(
    'nome', p.nome, 'descricao', p.descricao, 'inicio', central_priv.dia(p.inicio), 'prazo', central_priv.dia(p.prazo),
    'status', p.status, 'cor', p.cor, 'checklist', p.checklist,
    'criadoEm', central_priv.iso(p.criado_em), 'criadoPor', p.criado_por, 'atualizadoEm', central_priv.iso(p.atualizado_em)))
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
    'atualizadoEm', central_priv.iso(t.atualizado_em)))
$$;
create or replace function central_priv.doc_pagina(p public.central_paginas) returns jsonb
language sql stable set search_path = '' as $$
  select p.extras || central_priv.sem_nulos(jsonb_build_object(
    'tipo', 'pagina', 'titulo', p.titulo, 'icone', p.icone, 'parentId', p.parent_id, 'conteudo', p.conteudo, 'ordem', p.ordem,
    'criadoEm', central_priv.iso(p.criado_em), 'criadoPor', p.criado_por, 'editadoPor', p.editado_por,
    'atualizadoEm', central_priv.iso(p.atualizado_em)))
$$;

-- Tudo o que o app enxerga, no formato de antes. As permissões são as das tabelas (security_invoker).
create view public.central_itens with (security_invoker = true) as
  select 'projetos'::text as colecao, p.id as doc_id, central_priv.doc_projeto(p) as dados, p.gravado_em as atualizado_em, p.gravado_por as atualizado_por
  from public.central_projetos p where p.excluido_em is null
  union all
  select case when t.privada then 'pessoal:' || t.dono::text else 'tarefas' end, t.id, central_priv.doc_tarefa(t), t.gravado_em, t.gravado_por
  from public.central_tarefas t where t.excluido_em is null
  union all
  select case when g.privada then 'pessoal:' || g.dono::text else 'paginas' end, g.id, central_priv.doc_pagina(g), g.gravado_em, g.gravado_por
  from public.central_paginas g where g.excluido_em is null
  union all
  select 'config', c.chave, central_priv.sem_nulos(c.valor), c.gravado_em, c.gravado_por from public.central_config c where c.excluido_em is null;
revoke all on public.central_itens from anon, authenticated;
grant select on public.central_itens to authenticated;

/* ---------- gravação ---------- */
-- Quem grava: a pessoa logada (regras do app) ou o servidor/conector do Claude (sem sessão de usuário, fora da API pública).
create or replace function central_priv.e_servidor() returns boolean
language sql stable set search_path = '' as $$
  select auth.jwt() = '{}'::jsonb and current_setting('role') not in ('anon', 'authenticated')
     and session_user not in ('authenticator', 'anon', 'authenticated') $$;

-- Grava o registro já validado nas tabelas. Usada pelas funções públicas e pela cópia inicial.
create or replace function central_priv.decompor(p_colecao text, p_id text, d jsonb, p_por uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  privada boolean := p_colecao like 'pessoal:%';
  dono uuid := case when p_colecao like 'pessoal:%' then substr(p_colecao, 9)::uuid end;
  tipo text;
  ex jsonb;
  proj text; pai text; deps jsonb;
begin
  if p_id is null or p_id = '' or length(p_id) > 200 then raise exception 'id inválido' using errcode = '22023'; end if;
  if d is null or jsonb_typeof(d) <> 'object' then raise exception 'dados devem ser um objeto' using errcode = '22023'; end if;
  tipo := case when p_colecao = 'projetos' then 'projeto' when p_colecao = 'config' then 'config'
               when p_colecao = 'tarefas' then 'tarefa' when p_colecao = 'paginas' then 'pagina'
               when privada then d->>'tipo' end;

  if tipo = 'config' then
    insert into public.central_config (chave, valor, gravado_em, gravado_por, excluido_em) values (p_id, d, now(), p_por, null)
    on conflict (chave) do update set valor = excluded.valor, gravado_em = now(), gravado_por = p_por, excluido_em = null;

  elsif tipo = 'projeto' then
    ex := d - array['nome','descricao','inicio','prazo','status','cor','checklist','criadoEm','criadoPor','atualizadoEm'];
    insert into public.central_projetos as p (id, nome, descricao, inicio, prazo, status, cor, checklist, criado_em, criado_por, atualizado_em, extras, gravado_em, gravado_por, excluido_em)
    values (p_id, coalesce(central_priv.txt(d,'nome'), ''), central_priv.txt(d,'descricao'), central_priv.data(d,'inicio'), central_priv.data(d,'prazo'),
            coalesce(central_priv.txt(d,'status'), 'ativo'), central_priv.txt(d,'cor'), central_priv.lista(d,'checklist'),
            central_priv.momento(d,'criadoEm'), central_priv.txt(d,'criadoPor'), central_priv.momento(d,'atualizadoEm'), central_priv.sem_nulos(ex), now(), p_por, null)
    on conflict (id) do update set nome = excluded.nome, descricao = excluded.descricao, inicio = excluded.inicio, prazo = excluded.prazo,
      status = excluded.status, cor = excluded.cor, checklist = excluded.checklist, criado_em = excluded.criado_em, criado_por = excluded.criado_por,
      atualizado_em = excluded.atualizado_em, extras = excluded.extras, gravado_em = now(), gravado_por = p_por, excluido_em = null;

  elsif tipo = 'tarefa' then
    ex := d - array['tipo','titulo','descricao','status','prioridade','inicio','prazo','foco','aguardando','respId','respNome','projetoId','paiId',
                    'recorrencia','proxGerada','arquivado','ordem','checklist','links','campos','historico','dependeDe','comentarios',
                    'criadoEm','criadoPor','concluidoEm','atualizadoEm'];
    -- referência a projeto/tarefa que não existe (ex.: excluído de vez antes do histórico) fica guardada em extras
    proj := central_priv.txt(d,'projetoId');
    if proj is not null and not exists (select 1 from public.central_projetos where id = proj) then ex := ex || jsonb_build_object('projetoId', proj); proj := null; end if;
    pai := central_priv.txt(d,'paiId');
    if pai is not null and (pai = p_id or not exists (select 1 from public.central_tarefas where id = pai)) then ex := ex || jsonb_build_object('paiId', pai); pai := null; end if;
    deps := central_priv.lista(d,'dependeDe');
    if deps is not null and (exists (select 1 from jsonb_array_elements(deps) e where jsonb_typeof(e) <> 'string')
        or exists (select 1 from jsonb_array_elements_text(deps) e(v) where v = p_id or not exists (select 1 from public.central_tarefas where id = v))
        or (select count(*) from jsonb_array_elements_text(deps)) <> (select count(distinct v) from jsonb_array_elements_text(deps) e(v))) then
      ex := ex || jsonb_build_object('dependeDe', deps); deps := null;
    end if;
    if jsonb_typeof(d->'campos') not in ('object','null') then raise exception 'campo campos deve ser objeto' using errcode = '22023'; end if;
    if d ? 'comentarios' and jsonb_typeof(d->'comentarios') <> 'null' and (jsonb_typeof(d->'comentarios') <> 'array'
        or exists (select 1 from jsonb_array_elements(d->'comentarios') c where jsonb_typeof(c) <> 'object' or jsonb_typeof(c->'id') is distinct from 'string')) then
      raise exception 'comentarios deve ser uma lista de objetos com id' using errcode = '22023';
    end if;

    insert into public.central_tarefas as t (id, privada, dono, titulo, descricao, status, prioridade, inicio, prazo, foco, aguardando, resp_id, resp_nome,
      projeto_id, pai_id, recorrencia, prox_gerada, arquivado, ordem, checklist, links, campos, historico, criado_em, criado_por, concluido_em, atualizado_em,
      extras, gravado_em, gravado_por, excluido_em)
    values (p_id, privada, dono, coalesce(central_priv.txt(d,'titulo'), ''), central_priv.txt(d,'descricao'), coalesce(central_priv.txt(d,'status'), 'afazer'),
      central_priv.txt(d,'prioridade'), central_priv.data(d,'inicio'), central_priv.data(d,'prazo'), central_priv.data(d,'foco'), central_priv.txt(d,'aguardando'),
      central_priv.txt(d,'respId'), central_priv.txt(d,'respNome'), proj, pai, central_priv.txt(d,'recorrencia'), central_priv.logico(d,'proxGerada'),
      central_priv.logico(d,'arquivado'), central_priv.numero(d,'ordem'), central_priv.lista(d,'checklist'), central_priv.lista(d,'links'),
      case when jsonb_typeof(d->'campos') = 'object' then d->'campos' end,
      central_priv.lista(d,'historico'), central_priv.momento(d,'criadoEm'), central_priv.txt(d,'criadoPor'), central_priv.momento(d,'concluidoEm'),
      central_priv.momento(d,'atualizadoEm'), central_priv.sem_nulos(ex), now(), p_por, null)
    on conflict (id) do update set privada = excluded.privada, dono = excluded.dono, titulo = excluded.titulo, descricao = excluded.descricao,
      status = excluded.status, prioridade = excluded.prioridade, inicio = excluded.inicio, prazo = excluded.prazo, foco = excluded.foco,
      aguardando = excluded.aguardando, resp_id = excluded.resp_id, resp_nome = excluded.resp_nome, projeto_id = excluded.projeto_id,
      pai_id = excluded.pai_id, recorrencia = excluded.recorrencia, prox_gerada = excluded.prox_gerada, arquivado = excluded.arquivado,
      ordem = excluded.ordem, checklist = excluded.checklist, links = excluded.links, campos = excluded.campos, historico = excluded.historico,
      criado_em = excluded.criado_em, criado_por = excluded.criado_por, concluido_em = excluded.concluido_em, atualizado_em = excluded.atualizado_em,
      extras = excluded.extras, gravado_em = now(), gravado_por = p_por, excluido_em = null;

    delete from public.central_dependencias where tarefa_id = p_id;
    insert into public.central_dependencias (tarefa_id, depende_de, ordem)
    select p_id, v, n::int from jsonb_array_elements_text(coalesce(deps, '[]')) with ordinality e(v, n);

    delete from public.central_comentarios where tarefa_id = p_id;
    insert into public.central_comentarios (tarefa_id, id, ordem, por, texto, em, extras)
    select p_id, c->>'id', n::int, central_priv.txt(c,'por'), coalesce(central_priv.txt(c,'texto'), ''), central_priv.momento(c,'em'),
           central_priv.sem_nulos(c - array['id','por','texto','em'])
    from jsonb_array_elements(coalesce(d->'comentarios', '[]')) with ordinality e(c, n)
    where jsonb_typeof(d->'comentarios') = 'array';

  elsif tipo = 'pagina' then
    ex := d - array['tipo','titulo','icone','parentId','conteudo','ordem','criadoEm','criadoPor','editadoPor','atualizadoEm'];
    pai := central_priv.txt(d,'parentId');
    if pai is not null and (pai = p_id or not exists (select 1 from public.central_paginas where id = pai)) then ex := ex || jsonb_build_object('parentId', pai); pai := null; end if;
    insert into public.central_paginas as g (id, privada, dono, titulo, icone, parent_id, conteudo, ordem, criado_em, criado_por, editado_por, atualizado_em, extras, gravado_em, gravado_por, excluido_em)
    values (p_id, privada, dono, coalesce(central_priv.txt(d,'titulo'), ''), central_priv.txt(d,'icone'), pai, central_priv.txt(d,'conteudo'),
      central_priv.numero(d,'ordem'), central_priv.momento(d,'criadoEm'), central_priv.txt(d,'criadoPor'), central_priv.txt(d,'editadoPor'),
      central_priv.momento(d,'atualizadoEm'), central_priv.sem_nulos(ex), now(), p_por, null)
    on conflict (id) do update set privada = excluded.privada, dono = excluded.dono, titulo = excluded.titulo, icone = excluded.icone,
      parent_id = excluded.parent_id, conteudo = excluded.conteudo, ordem = excluded.ordem, criado_em = excluded.criado_em,
      criado_por = excluded.criado_por, editado_por = excluded.editado_por, atualizado_em = excluded.atualizado_em, extras = excluded.extras,
      gravado_em = now(), gravado_por = p_por, excluido_em = null;
  else
    raise exception 'coleção ou tipo desconhecido: % / %', p_colecao, coalesce(d->>'tipo', '(sem tipo)') using errcode = '22023';
  end if;
end $$;
revoke all on function central_priv.decompor(text, text, jsonb, uuid) from public, anon, authenticated;

-- O registro como o app o vê agora (ou null se não existe nessa coleção)
create or replace function central_priv.doc_atual(p_colecao text, p_id text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select dados from public.central_itens where colecao = p_colecao and doc_id = p_id $$;
revoke all on function central_priv.doc_atual(text, text) from public, anon, authenticated;

-- Exclusão lógica: some do app, mas a linha e as relações ficam (para restaurar e para o histórico).
-- Devolve como o item estava, ou null se ele não está nessa coleção.
create or replace function central_priv.marcar_excluido(p_colecao text, p_id text, p_por uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare antes jsonb := central_priv.doc_atual(p_colecao, p_id);
begin
  if antes is null then return null; end if;
  if p_colecao = 'projetos' then update public.central_projetos set excluido_em = now(), gravado_por = p_por where id = p_id;
  elsif p_colecao = 'config' then update public.central_config set excluido_em = now(), gravado_por = p_por where chave = p_id;
  elsif p_colecao = 'tarefas' or antes->>'tipo' = 'tarefa' then update public.central_tarefas set excluido_em = now(), gravado_por = p_por where id = p_id;
  else update public.central_paginas set excluido_em = now(), gravado_por = p_por where id = p_id;
  end if;
  return antes;
end $$;
revoke all on function central_priv.marcar_excluido(text, text, uuid) from public, anon, authenticated;

create or replace function public.central_gravar(p_colecao text, p_id text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare antes jsonb; depois jsonb; por uuid := auth.uid();
begin
  if not (central_priv.e_servidor() or (por is not null and central_priv.pode_ver(p_colecao))) then
    raise exception 'sem permissão para gravar em %', p_colecao using errcode = '42501';
  end if;
  if not (p_colecao in ('tarefas','projetos','paginas','config') or p_colecao ~ '^pessoal:[0-9a-f-]{36}$') then
    raise exception 'coleção desconhecida: %', p_colecao using errcode = '22023';
  end if;
  -- não deixa sobrescrever item pessoal de outra pessoa com o mesmo id
  if exists (select 1 from public.central_tarefas t where t.id = p_id and t.excluido_em is null and t.privada and t.dono is distinct from por and not central_priv.e_servidor())
     or exists (select 1 from public.central_paginas g where g.id = p_id and g.excluido_em is null and g.privada and g.dono is distinct from por and not central_priv.e_servidor()) then
    raise exception 'sem permissão para alterar este item' using errcode = '42501';
  end if;
  antes := central_priv.doc_atual(p_colecao, p_id);
  perform central_priv.decompor(p_colecao, p_id, p_dados, por);
  depois := central_priv.doc_atual(p_colecao, p_id);
  if antes is distinct from depois then
    insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por)
    values (p_colecao, p_id, case when antes is null then 'criar' else 'editar' end, depois, por);
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
  if antes is null then return false; end if;  -- já não está nessa coleção (ex.: foi movido entre Pessoal e Time)
  insert into public.central_docs_historico (colecao, doc_id, operacao, dados, por) values (p_colecao, p_id, 'excluir', antes, por);
  return true;
end $$;
revoke all on function public.central_gravar(text, text, jsonb), public.central_excluir(text, text) from public, anon;
grant execute on function public.central_gravar(text, text, jsonb), public.central_excluir(text, text) to authenticated;

-- A lixeira passa a olhar as tabelas novas (que o espelho abaixo mantém iguais a central_docs até a troca)
create or replace view public.central_lixeira with (security_invoker = true) as
select distinct on (h.doc_id) h.colecao, h.doc_id, h.dados, h.em, h.por
from public.central_docs_historico h
where h.operacao = 'excluir'
  and not exists (select 1 from public.central_itens i where i.doc_id = h.doc_id)
order by h.doc_id, h.id desc;

-- Tempo real: o app passa a ouvir as tabelas novas na etapa 2
alter publication supabase_realtime add table public.central_projetos, public.central_tarefas, public.central_dependencias,
  public.central_comentarios, public.central_paginas, public.central_config;

/* ---------- cópia dos dados de central_docs ---------- */
-- Projetos e configuração primeiro, depois tarefas e páginas duas vezes (a segunda liga subtarefas, dependências e subpáginas
-- que apontam para itens copiados depois). Pode ser rodada de novo na troca: só regrava.
create or replace function central_priv.copiar_de_docs() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select colecao, doc_id, dados, atualizado_por from public.central_docs where colecao in ('projetos','config') loop
    perform central_priv.decompor(r.colecao, r.doc_id, r.dados, r.atualizado_por); n := n + 1;
  end loop;
  for i in 1..2 loop
    for r in select colecao, doc_id, dados, atualizado_por from public.central_docs where colecao not in ('projetos','config') order by doc_id loop
      perform central_priv.decompor(r.colecao, r.doc_id, r.dados, r.atualizado_por);
      if i = 1 then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function central_priv.copiar_de_docs() from public, anon, authenticated;

-- Forma equivalente para o app: sem campos nulos (também nos comentários) e com os padrões que o app já assume
-- (tarefa sem situação = "A fazer", projeto sem situação = "Ativo", sem título = vazio).
create or replace function central_priv.normalizar(p_colecao text, d jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select case
    when p_colecao = 'projetos' then jsonb_build_object('nome', '', 'status', 'ativo') || x
    when p_colecao = 'tarefas' or x->>'tipo' = 'tarefa' then
      jsonb_build_object('titulo', '', 'status', 'afazer') || x
      || case when jsonb_typeof(x->'comentarios') = 'array'
              then jsonb_build_object('comentarios', (select coalesce(jsonb_agg(central_priv.sem_nulos(c) order by n), '[]') from jsonb_array_elements(x->'comentarios') with ordinality e(c, n)))
              else '{}' end
    when p_colecao = 'paginas' or x->>'tipo' = 'pagina' then jsonb_build_object('titulo', '') || x
    else x end
  from (select central_priv.sem_nulos(d) as x) s
$$;

-- Conferência: lista o que ficou diferente entre central_docs e central_itens (vazio = cópia perfeita)
create or replace function central_priv.conferir_copia() returns table (colecao text, doc_id text, problema text)
language sql stable security definer set search_path = '' as $$
  select coalesce(d.colecao, i.colecao), coalesce(d.doc_id, i.doc_id),
         case when i.doc_id is null then 'faltou na cópia' when d.doc_id is null then 'sobrou na cópia' else 'conteúdo diferente' end
  from public.central_docs d
  full join public.central_itens i on i.colecao = d.colecao and i.doc_id = d.doc_id
  where i.doc_id is null or d.doc_id is null or central_priv.normalizar(d.colecao, d.dados) <> i.dados
$$;
revoke all on function central_priv.conferir_copia() from public, anon, authenticated;

/* ---------- espelho durante a transição ---------- */
-- Enquanto o app (Vercel e versão do Claude) ainda grava em central_docs, cada gravação é repetida nas tabelas novas.
-- Se algum dado antigo não passar na validação, a gravação do app NÃO falha: o problema fica anotado em central_espelho_falhas
-- e aparece em conferir_copia(). Depois da troca, ninguém mais grava em central_docs e este espelho pode ser desligado.
create table public.central_espelho_falhas (
  id bigint generated always as identity primary key,
  colecao text, doc_id text, erro text, em timestamptz not null default now()
);
alter table public.central_espelho_falhas enable row level security;
revoke all on public.central_espelho_falhas from anon, authenticated;

create or replace function central_priv.espelhar() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_op = 'DELETE' then perform central_priv.marcar_excluido(old.colecao, old.doc_id, auth.uid());
    else perform central_priv.decompor(new.colecao, new.doc_id, new.dados, auth.uid());
    end if;
  exception when others then
    insert into public.central_espelho_falhas (colecao, doc_id, erro)
    values (coalesce(new.colecao, old.colecao), coalesce(new.doc_id, old.doc_id), sqlstate || ': ' || sqlerrm);
  end;
  return null;
end $$;
revoke all on function central_priv.espelhar() from public, anon, authenticated;
create trigger central_docs_espelho after insert or update or delete on public.central_docs
  for each row execute function central_priv.espelhar();

select central_priv.copiar_de_docs();

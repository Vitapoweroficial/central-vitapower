-- Permissões por projeto (006): dono, editor, leitor; projeto restrito some para quem não tem acesso, inclusive pela API direta.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
create function t.erro(cmd text, codigo text, nome text) returns void language plpgsql as $$
begin
  begin execute cmd; exception when others then
    if sqlstate <> codigo then raise exception 'FALHOU: % (erro % em vez de %: %)', nome, sqlstate, codigo, sqlerrm; end if;
    return;
  end;
  raise exception 'FALHOU: % (comando foi aceito)', nome;
end $$;
grant usage on schema t to authenticated, anon; grant execute on all functions in schema t to authenticated, anon;

-- a = dona, b = leitora, c = editora, d = colega sem acesso, x = de fora, andrew = administrador
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'c@vitapowernutrition.com.br'),
  ('dddddddd-0000-0000-0000-000000000004', 'd@vitapowernutrition.com.br'),
  ('eeeeeeee-0000-0000-0000-000000000005', 'andrew@vitapowernutrition.com.br');
set local role authenticated;

-- Projeto aberto continua como antes: todos veem e editam
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('projetos', 'aberto', '{"nome":"Aberto"}');
select t.ok((select dados->>'_papel' from public.central_itens where doc_id = 'aberto') = 'dono', 'quem cria o projeto é dono');
select t.como('dddddddd-0000-0000-0000-000000000004', 'd@vitapowernutrition.com.br');
select t.ok((select dados->>'_papel' from public.central_itens where doc_id = 'aberto') = 'editor', 'em projeto aberto, colega é editor');
select public.central_gravar('tarefas', 'ta', '{"tipo":"tarefa","titulo":"No aberto","projetoId":"aberto"}');
select t.erro($$select public.central_gravar('projetos', 'aberto', '{"nome":"Aberto","acesso":"restrito","membros":[]}')$$, '42501', 'editor não muda quem tem acesso');
select t.erro($$select public.central_excluir('projetos', 'aberto')$$, '42501', 'editor não exclui projeto que tem dono');

-- A cria um projeto restrito: B leitora, C editora
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('projetos', 'sigilo', '{"nome":"Fórmula nova","acesso":"restrito","membros":[
  {"id":"bbbbbbbb-0000-0000-0000-000000000002","papel":"leitor"},{"id":"cccccccc-0000-0000-0000-000000000003","papel":"editor"}]}');
select t.ok((select jsonb_array_length(dados->'membros') from public.central_itens where doc_id = 'sigilo') = 3, 'dona entra na lista junto com as escolhidas');
select public.central_gravar('tarefas', 'ts', '{"tipo":"tarefa","titulo":"Teste de estabilidade","projetoId":"sigilo",
  "comentarios":[{"id":"m1","texto":"segredo"}]}');
select t.ok(not exists (select 1 from public.central_docs_historico where dados ? '_papel'), 'histórico não guarda o papel de quem viu');

-- Cenário D: D não vê nada do projeto restrito, nem direto nas tabelas, e não consegue alterar
select t.como('dddddddd-0000-0000-0000-000000000004', 'd@vitapowernutrition.com.br');
select t.ok(not exists (select 1 from public.central_itens where doc_id in ('sigilo','ts')), 'sem acesso: não vê projeto nem tarefa');
select t.ok(not exists (select 1 from public.central_projetos where id = 'sigilo'), 'sem acesso: tabela de projetos');
select t.ok(not exists (select 1 from public.central_tarefas where id = 'ts'), 'sem acesso: tabela de tarefas');
select t.ok(not exists (select 1 from public.central_comentarios where tarefa_id = 'ts'), 'sem acesso: comentários');
select t.ok(not exists (select 1 from public.central_projeto_membros where projeto_id = 'sigilo'), 'sem acesso: lista de membros');
select t.ok(not exists (select 1 from public.central_docs_historico where doc_id in ('sigilo','ts')), 'sem acesso: histórico');
select t.erro($$select public.central_gravar('tarefas', 'ts', '{"tipo":"tarefa","titulo":"invadida"}')$$, '42501', 'sem acesso: não altera a tarefa');
select t.erro($$select public.central_gravar('projetos', 'sigilo', '{"nome":"invadido"}')$$, '42501', 'sem acesso: não altera o projeto');
select t.erro($$select public.central_gravar('tarefas', 'td', '{"tipo":"tarefa","titulo":"entrar","projetoId":"sigilo"}')$$, '42501', 'sem acesso: não cria tarefa no projeto');
select t.erro($$select public.central_gravar('tarefas', 'ta', '{"tipo":"tarefa","titulo":"No aberto","projetoId":"sigilo"}')$$, '42501', 'sem acesso: não move tarefa para o projeto');
select t.erro($$select public.central_excluir('tarefas', 'ts')$$, '42501', 'sem acesso: não exclui a tarefa');
select t.ok((select count(*) from public.central_itens where doc_id = 'aberto') = 1, 'continua vendo o projeto aberto');

-- B leitora: vê, mas não altera
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.ok((select dados->>'_papel' from public.central_itens where doc_id = 'sigilo') = 'leitor', 'leitora vê o próprio papel');
select t.ok(exists (select 1 from public.central_itens where doc_id = 'ts'), 'leitora vê a tarefa');
select t.ok(exists (select 1 from public.central_docs_historico where doc_id = 'ts'), 'leitora vê o histórico');
select t.erro($$select public.central_gravar('tarefas', 'ts', '{"tipo":"tarefa","titulo":"x","projetoId":"sigilo"}')$$, '42501', 'leitora não edita tarefa');
select t.erro($$select public.central_gravar('projetos', 'sigilo', '{"nome":"x"}')$$, '42501', 'leitora não edita projeto');

-- C editora: edita tarefas e projeto, mas não muda acesso nem exclui o projeto
select t.como('cccccccc-0000-0000-0000-000000000003', 'c@vitapowernutrition.com.br');
select public.central_gravar('tarefas', 'ts', '{"tipo":"tarefa","titulo":"Teste de estabilidade 2","projetoId":"sigilo"}');
select public.central_gravar('projetos', 'sigilo', (select dados from public.central_itens where doc_id = 'sigilo') || '{"descricao":"ok"}');
select t.erro($$select public.central_gravar('projetos', 'sigilo', '{"nome":"x","acesso":"time"}')$$, '42501', 'editora não abre o projeto');
select t.erro($$select public.central_excluir('projetos', 'sigilo')$$, '42501', 'editora não exclui o projeto');
select t.ok(public.central_excluir('tarefas', 'ts'), 'editora exclui tarefa');

-- Administrador vê e pode tudo; dono não pode deixar projeto restrito sem dono
select t.como('eeeeeeee-0000-0000-0000-000000000005', 'andrew@vitapowernutrition.com.br');
select t.ok((select dados->>'_papel' from public.central_itens where doc_id = 'sigilo') = 'dono', 'administrador é dono de tudo');
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.erro($$select public.central_gravar('projetos', 'sigilo', '{"nome":"x","acesso":"restrito","membros":[{"id":"bbbbbbbb-0000-0000-0000-000000000002","papel":"editor"}]}')$$,
  '22023', 'projeto restrito precisa de dono');
select t.erro($$select public.central_gravar('projetos', 'sigilo', '{"nome":"x","membros":[{"id":"zz","papel":"editor"}]}')$$, '22023', 'membro inválido');
-- dona abre o projeto ao time: D passa a ver
select public.central_gravar('projetos', 'sigilo', '{"nome":"Fórmula nova","acesso":"time"}');
select t.como('dddddddd-0000-0000-0000-000000000004', 'd@vitapowernutrition.com.br');
select t.ok(exists (select 1 from public.central_itens where doc_id = 'sigilo'), 'projeto aberto ao time aparece para todos');
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.ok(public.central_excluir('projetos', 'sigilo'), 'dona exclui o projeto');
rollback;

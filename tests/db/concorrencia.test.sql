-- Edição simultânea (005): versão por item, recusa de gravação feita sobre versão velha, histórico sem o número de versão.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
create function t.erro(cmd text, codigo text, nome text) returns text language plpgsql as $$
begin
  begin execute cmd; exception when others then
    if sqlstate <> codigo then raise exception 'FALHOU: % (erro % em vez de %: %)', nome, sqlstate, codigo, sqlerrm; end if;
    return sqlerrm;
  end;
  raise exception 'FALHOU: % (comando foi aceito)', nome;
end $$;
create function t.v(c text, id text) returns numeric language sql as $$
  select (dados->>'_versao')::numeric from public.central_itens where colecao = c and doc_id = id $$;
grant usage on schema t to authenticated, anon; grant execute on all functions in schema t to authenticated, anon;

insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');

set local role authenticated;
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","titulo":"Original","atualizadoEm":"2026-10-30T10:00:00.000Z"}');
select t.ok(t.v('tarefas', 'x') = 1, 'item novo começa na versão 1');

-- A e B abriram a tarefa na versão 1. B salva primeiro.
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.ok((public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","titulo":"Mudança da B","_versao":1}')->>'_versao')::int = 2,
  'gravação devolve a versão nova');

-- A tenta salvar por cima da versão 1: é recusada, com a versão atual e quem salvou
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.ok(t.erro($$select public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","titulo":"Mudança da A","_versao":1}')$$, 'CV409', 'versão velha é recusada')
  = 'conflito:2:bbbbbbbb-0000-0000-0000-000000000002', 'erro diz a versão atual e quem salvou');
select t.ok((select dados->>'titulo' from public.central_itens where doc_id = 'x') = 'Mudança da B', 'mudança da B não foi apagada');

-- A decide salvar a dela por cima: manda a versão atual e passa
select public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","titulo":"Mudança da A","_versao":2}');
select t.ok(t.v('tarefas', 'x') = 3, 'versão sobe a cada alteração');

-- Salvar sem mudar nada não sobe a versão (não gera conflito à toa para os outros)
select public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","titulo":"Mudança da A","_versao":3}');
select t.ok(t.v('tarefas', 'x') = 3, 'salvar igual não sobe a versão');

-- Sem _versao (item restaurado, versão antiga) continua aceito
select public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","titulo":"Restaurada"}');
select t.ok(t.v('tarefas', 'x') = 4, 'gravação sem versão é aceita');

-- _versao de item que ainda não existe (cópia de outro item) não bloqueia
select public.central_gravar('tarefas', 'y', '{"tipo":"tarefa","titulo":"Cópia","_versao":7}');
select t.ok(t.v('tarefas', 'y') = 1, 'cópia com _versao de outro item vira versão 1');

-- Também vale para projetos, páginas e configuração
select public.central_gravar('projetos', 'p', '{"nome":"P"}');
select t.erro($$select public.central_gravar('projetos', 'p', '{"nome":"P2","_versao":0}')$$, 'CV409', 'conflito em projeto');
select public.central_gravar('paginas', 'g', '{"tipo":"pagina","titulo":"G","conteudo":"<p>a</p>"}');
select public.central_gravar('paginas', 'g', '{"tipo":"pagina","titulo":"G","conteudo":"<p>b</p>","_versao":1}');
select t.erro($$select public.central_gravar('paginas', 'g', '{"tipo":"pagina","titulo":"G","conteudo":"<p>c</p>","_versao":1}')$$, 'CV409', 'conflito em página');
select public.central_gravar('config', 'campos', '{"lista":[]}');
select t.ok(t.v('config', 'campos') = 1, 'configuração também tem versão');
select t.erro($$select public.central_gravar('config', 'campos', '{"lista":[1],"_versao":5}')$$, 'CV409', 'conflito em configuração');
select t.erro($$select public.central_gravar('tarefas', 'x', '{"tipo":"tarefa","_versao":"3"}')$$, '22023', '_versao tem de ser número');

-- O número de versão não vai para o histórico nem para os campos extras
select t.ok(not exists (select 1 from public.central_docs_historico where dados ? '_versao'), 'histórico sem _versao');
select t.ok(not exists (select 1 from public.central_tarefas where extras ? '_versao'), 'extras sem _versao');
select t.ok((select count(*) from public.central_docs_historico where doc_id = 'x') = 4, 'uma versão no histórico por alteração real');
select public.central_excluir('tarefas', 'y');
select t.ok(not exists (select 1 from public.central_lixeira where dados ? '_versao'), 'lixeira sem _versao');
rollback;

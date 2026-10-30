-- Modelo relacional (004): cópia sem perda, gravação validada, permissões, exclusão lógica, histórico e lixeira.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
-- espera erro com o código dado ao rodar o comando
create function t.erro(cmd text, codigo text, nome text) returns void language plpgsql as $$
begin
  begin execute cmd; exception when others then
    if sqlstate <> codigo then raise exception 'FALHOU: % (erro % em vez de %: %)', nome, sqlstate, codigo, sqlerrm; end if;
    return;
  end;
  raise exception 'FALHOU: % (comando foi aceito)', nome;
end $$;
grant usage on schema t to authenticated, anon; grant execute on all functions in schema t to authenticated, anon;

insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com');

-- 1) Cópia de central_docs: todos os campos que o app usa voltam iguais
insert into public.central_docs (colecao, doc_id, dados) values
 ('projetos', 'p1', '{"nome":"Lançamento","descricao":"x","inicio":"2026-11-01","prazo":"2026-12-01","status":"ativo","cor":"p2","checklist":[{"id":"c1","t":"Aprovar","ok":true}],"criadoEm":"2026-10-28T00:27:23.643Z","criadoPor":"u_antigo","atualizadoEm":"2026-10-28T00:27:23.643Z","modeloUsado":"lanc"}'),
 ('tarefas', 't2', '{"tipo":"tarefa","titulo":"Base","dependeDe":[],"comentarios":[],"status":"feito","prioridade":"baixa","ordem":1793147823221.5,"concluidoEm":"2026-10-29T10:00:00.000Z"}'),
 ('tarefas', 't1', '{"tipo":"tarefa","titulo":"Completa","descricao":"linha1\nlinha2","status":"aguardando","prioridade":"alta","inicio":"2026-11-02","prazo":"2026-11-05","foco":"2026-11-03","aguardando":"fornecedor","respId":"bbbbbbbb-0000-0000-0000-000000000002","respNome":null,"projetoId":"p1","paiId":"t2","dependeDe":["t2"],"recorrencia":"semanal","proxGerada":false,"arquivado":false,"ordem":5,"checklist":[{"id":"k","t":"passo","ok":false}],"links":[{"id":"l","nome":"Drive","url":"https://x"}],"campos":{"cli":"ACME","n":null},"historico":[{"de":"afazer","para":"aguardando","em":"2026-10-28T00:37:02.071Z","por":"u_antigo"}],"comentarios":[{"id":"m1","por":"aaaaaaaa-0000-0000-0000-000000000001","texto":"oi","em":"2026-10-28T01:00:00.000Z"},{"id":"m2","por":null,"texto":"dois","em":"2026-10-28T02:00:00.000Z","editado":true}],"criadoEm":"2026-10-28T00:25:59.992Z","criadoPor":"u_antigo","atualizadoEm":"2026-10-28T00:43:54.699Z","campoNovoDoApp":[1,2]}'),
 ('tarefas', 't3', '{"tipo":"tarefa","titulo":"Aponta para o que não existe","projetoId":"sumiu","paiId":"sumiu2","dependeDe":["sumiu3"]}'),
 ('paginas', 'g2', '{"tipo":"pagina","titulo":"Filha","parentId":"g1","conteudo":"<p>b</p>","ordem":2}'),
 ('paginas', 'g1', '{"tipo":"pagina","titulo":"Mãe","icone":"🏭","parentId":null,"conteudo":"<h2>a</h2>","ordem":1,"editadoPor":"u_antigo","criadoEm":"2026-10-28T02:42:44.909Z","atualizadoEm":"2026-10-28T02:43:24.545Z"}'),
 ('config', 'campos', '{"lista":[{"id":"cli","nome":"Cliente","tipo":"texto"}],"atualizadoEm":"2026-10-28T00:00:00.000Z","por":null}'),
 ('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'pa', '{"tipo":"tarefa","titulo":"Só minha","status":"afazer"}'),
 ('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'pg', '{"tipo":"pagina","titulo":"Nota minha"}');
select t.ok(central_priv.copiar_de_docs() = 9, 'copia os 9 registros');
select t.ok(not exists (select 1 from central_priv.conferir_copia()), 'cópia idêntica ao original (conferir_copia vazio)');
select t.ok((select pai_id = 't2' and projeto_id = 'p1' from public.central_tarefas where id = 't1'), 'subtarefa e projeto viram chaves estrangeiras');
select t.ok((select count(*) from public.central_dependencias where tarefa_id = 't1') = 1, 'dependência vira linha própria');
select t.ok((select count(*) from public.central_comentarios where tarefa_id = 't1') = 2, 'comentários viram linhas próprias');
select t.ok((select extras ? 'projetoId' and extras ? 'paiId' and extras ? 'dependeDe' and projeto_id is null from public.central_tarefas where id = 't3'),
  'referência a item inexistente não quebra a cópia e fica guardada');
select t.ok((select parent_id from public.central_paginas where id = 'g2') = 'g1', 'subpágina ligada à página mãe');
select t.ok(central_priv.copiar_de_docs() = 9 and not exists (select 1 from central_priv.conferir_copia()), 'cópia pode rodar de novo sem duplicar');
select t.ok((select count(*) from public.central_tarefas) = 4, 'sem tarefas duplicadas');

-- 2) Permissões de leitura
set local role authenticated;
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.ok((select count(*) from public.central_itens where colecao like 'pessoal:%') = 0, 'colega não vê itens pessoais de outro');
select t.ok((select count(*) from public.central_tarefas where privada) = 0, 'colega não lê tarefa pessoal de outro direto na tabela');
select t.ok((select count(*) from public.central_itens where colecao = 'tarefas') = 3, 'colega vê as tarefas do time');
select t.como('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com');
select t.ok((select count(*) from public.central_itens) = 0, 'pessoa de fora não vê nada');
select t.ok((select count(*) from public.central_comentarios) = 0, 'pessoa de fora não vê comentários');

-- 3) Gravação: só pelas funções, com permissão e validação
select t.erro($$select public.central_gravar('tarefas', 'z', '{"titulo":"invasão"}')$$, '42501', 'pessoa de fora não grava');
select t.erro($$select public.central_excluir('tarefas', 't2')$$, '42501', 'pessoa de fora não exclui');
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.erro($$insert into public.central_tarefas (id, titulo) values ('d', 'direto')$$, '42501', 'ninguém grava direto na tabela');
select t.erro($$update public.central_tarefas set titulo = 'x'$$, '42501', 'ninguém altera direto na tabela');
select t.erro($$select public.central_gravar('tarefas', 'v', '{"titulo":"x","prazo":"amanhã"}')$$, '22007', 'data inválida é recusada');
select t.erro($$select public.central_gravar('tarefas', 'v', '{"titulo":"x","status":"talvez"}')$$, '23514', 'situação inválida é recusada');
select t.erro($$select public.central_gravar('tarefas', 'v', '{"titulo":7}')$$, '22023', 'tipo de campo errado é recusado');
select t.erro($$select public.central_gravar('pessoal:bbbbbbbb-0000-0000-0000-000000000002', 'v', '{"tipo":"tarefa"}')$$, '42501', 'não grava no pessoal de outro');
select t.erro($$select public.central_gravar('qualquer', 'v', '{}')$$, '22023', 'coleção desconhecida é recusada');

select t.ok((public.central_gravar('tarefas', 'n1', '{"tipo":"tarefa","titulo":"Nova","status":"afazer","prioridade":"media"}'))->>'titulo' = 'Nova', 'membro cria tarefa');
select t.ok((select numero from public.central_tarefas where id = 'n1') is not null, 'tarefa nova recebe número permanente');
select public.central_gravar('tarefas', 'n1', '{"tipo":"tarefa","titulo":"Nova","status":"fazendo","prioridade":"media"}');
select public.central_gravar('tarefas', 'n1', '{"tipo":"tarefa","titulo":"Nova","status":"fazendo","prioridade":"media"}');
select t.ok((select array_agg(operacao order by id) from public.central_docs_historico where doc_id = 'n1') = '{criar,editar}', 'histórico: criar + editar; regravar igual não gera versão');
select t.ok((select gravado_por from public.central_tarefas where id = 'n1') = 'aaaaaaaa-0000-0000-0000-000000000001', 'registra quem gravou');

-- 4) Mover entre Pessoal e Time (o app grava no destino e exclui na origem)
select public.central_gravar('tarefas', 'pa', '{"tipo":"tarefa","titulo":"Só minha","status":"afazer"}');
select t.ok(public.central_excluir('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'pa') = false, 'excluir na origem depois de mover não apaga nada');
select t.ok((select not privada and excluido_em is null from public.central_tarefas where id = 'pa'), 'tarefa movida para o time continua viva');
select t.ok((select count(*) from public.central_lixeira where doc_id = 'pa') = 0, 'mover não vai para a lixeira');
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.erro($$select public.central_gravar('tarefas', 'pg', '{"tipo":"pagina"}')$$, '42501', 'colega não toma item pessoal de outro pelo id');

-- 5) Exclusão lógica: projeto some, relações ficam, lixeira mostra, restaurar traz tudo de volta
select t.ok(public.central_excluir('projetos', 'p1'), 'membro exclui projeto');
select t.ok((select count(*) from public.central_itens where doc_id = 'p1') = 0, 'projeto excluído some do app');
select t.ok((select projeto_id from public.central_tarefas where id = 't1') = 'p1', 'tarefas continuam ligadas ao projeto excluído');
select t.ok((select count(*) from public.central_lixeira where doc_id = 'p1') = 1, 'projeto excluído aparece na lixeira');
select public.central_gravar('projetos', 'p1', (select dados from public.central_lixeira where doc_id = 'p1'));
select t.ok((select count(*) from public.central_lixeira where doc_id = 'p1') = 0, 'restaurado sai da lixeira');
select t.ok((select dados->>'nome' from public.central_itens where doc_id = 'p1') = 'Lançamento', 'projeto volta igual');

-- 7) Espelho: o app atual ainda grava em central_docs e as tabelas novas acompanham
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
insert into public.central_docs (colecao, doc_id, dados) values ('tarefas', 'e1', '{"tipo":"tarefa","titulo":"Pelo app antigo","status":"afazer"}');
update public.central_docs set dados = '{"tipo":"tarefa","titulo":"Pelo app antigo","status":"feito"}' where doc_id = 'e1';
select t.ok((select status from public.central_tarefas where id = 'e1') = 'feito', 'gravação no formato antigo chega às tabelas novas');
delete from public.central_docs where doc_id = 'e1';
select t.ok((select excluido_em is not null from public.central_tarefas where id = 'e1'), 'exclusão no formato antigo vira exclusão lógica');
insert into public.central_docs (colecao, doc_id, dados) values ('tarefas', 'e2', '{"tipo":"tarefa","titulo":"Data torta","prazo":"31/12"}');
select t.ok((select count(*) from public.central_docs where doc_id = 'e2') = 1, 'dado antigo inválido não trava o app');
reset role;
select t.ok((select count(*) from public.central_espelho_falhas where doc_id = 'e2') = 1, 'dado inválido fica anotado nas falhas do espelho');
select t.ok(exists (select 1 from central_priv.conferir_copia() where doc_id = 'e2' and problema = 'faltou na cópia'), 'conferência aponta o item que não passou');
set local role authenticated;

-- 6) Servidor/conector (sem sessão de usuário) grava; anon não
reset role;
select set_config('request.jwt.claims', '', true);
select t.ok((public.central_gravar('tarefas', 's1', '{"tipo":"tarefa","titulo":"Pelo conector"}'))->>'titulo' = 'Pelo conector', 'conector do Claude grava');
set local role anon;
select t.erro($$select public.central_gravar('tarefas', 'an', '{}')$$, '42501', 'anon não chama a função de gravar');
select t.erro($$select 1 from public.central_itens$$, '42501', 'anon não lê os itens');
rollback;

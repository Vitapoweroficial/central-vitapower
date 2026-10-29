-- Histórico de versões e lixeira: o banco registra tudo e respeita quem pode ver o quê.
-- Pessoas: A e B são do time (domínio da empresa); X é de fora.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
grant usage on schema t to authenticated; grant execute on function t.ok(boolean, text) to authenticated;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email, 'role', 'authenticated')::text, true) $$;
grant execute on function t.como(text, text) to authenticated;

insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com');

set local role authenticated;

-- A cria, edita, regrava igual e exclui uma tarefa do time
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
insert into public.central_docs (colecao, doc_id, dados) values ('tarefas', 't1', '{"titulo":"Comprar embalagem","status":"afazer"}');
update public.central_docs set dados = '{"titulo":"Comprar embalagem","status":"fazendo"}' where doc_id = 't1';
update public.central_docs set dados = '{"titulo":"Comprar embalagem","status":"fazendo"}' where doc_id = 't1';
select t.ok((select array_agg(operacao order by id) from public.central_docs_historico where doc_id = 't1') = '{criar,editar}',
  'criar + editar viram versões; regravar igual não gera versão');
select t.ok((select por from public.central_docs_historico where doc_id = 't1' order by id desc limit 1) = 'aaaaaaaa-0000-0000-0000-000000000001',
  'versão registra quem alterou');
delete from public.central_docs where doc_id = 't1';
select t.ok((select dados->>'status' from public.central_docs_historico where doc_id = 't1' and operacao = 'excluir') = 'fazendo',
  'exclusão guarda o último conteúdo');
select t.ok((select count(*) from public.central_lixeira where doc_id = 't1') = 1, 'tarefa excluída aparece na lixeira');

-- A tem um item pessoal e o move para o time (grava no time e exclui no pessoal): não é exclusão
insert into public.central_docs (colecao, doc_id, dados) values ('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'p1', '{"titulo":"Ideia","tipo":"pagina"}');
insert into public.central_docs (colecao, doc_id, dados) values ('tarefas', 'm1', '{"titulo":"Mover"}');
insert into public.central_docs (colecao, doc_id, dados) values ('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'm1', '{"titulo":"Mover"}');
delete from public.central_docs where colecao = 'tarefas' and doc_id = 'm1';
select t.ok((select count(*) from public.central_lixeira where doc_id = 'm1') = 0, 'item movido entre Pessoal e Time não vai para a lixeira');

-- B, do time, vê o histórico e a lixeira do time, mas não nada do pessoal de A
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.ok((select count(*) from public.central_docs_historico where doc_id = 't1') = 3, 'colega do time vê o histórico da tarefa do time');
select t.ok((select count(*) from public.central_lixeira where doc_id = 't1') = 1, 'colega do time vê a lixeira do time');
select t.ok((select count(*) from public.central_docs_historico where colecao like 'pessoal:%') = 0, 'colega não vê histórico pessoal de outra pessoa');

-- X, de fora, não vê nada
select t.como('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com');
select t.ok((select count(*) from public.central_docs_historico) = 0, 'pessoa de fora não vê histórico');
select t.ok((select count(*) from public.central_lixeira) = 0, 'pessoa de fora não vê a lixeira');

-- Ninguém grava, altera ou apaga o histórico direto (nem quem é do time)
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
do $$ begin
  begin insert into public.central_docs_historico (colecao, doc_id, operacao) values ('tarefas', 'falso', 'criar');
        raise exception 'FALHOU: insert direto no histórico foi aceito';
  exception when insufficient_privilege then null; end;
  begin update public.central_docs_historico set dados = '{}';
        raise exception 'FALHOU: update direto no histórico foi aceito';
  exception when insufficient_privilege then null; end;
  begin delete from public.central_docs_historico;
        raise exception 'FALHOU: delete direto no histórico foi aceito';
  exception when insufficient_privilege then null; end;
end $$;

-- Restaurar = gravar de volta o conteúdo; some da lixeira e o histórico mostra a volta
insert into public.central_docs (colecao, doc_id, dados)
select colecao, doc_id, dados from public.central_lixeira where doc_id = 't1';
select t.ok((select dados->>'status' from public.central_docs where doc_id = 't1') = 'fazendo', 'restaurar traz o último conteúdo');
select t.ok((select count(*) from public.central_lixeira where doc_id = 't1') = 0, 'restaurado sai da lixeira');
select t.ok((select count(*) from public.central_docs_historico where doc_id = 't1') = 4, 'restauração fica registrada no histórico');

-- Pessoa de fora não consegue restaurar (gravar) item do time
select t.como('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com');
do $$ begin
  begin insert into public.central_docs (colecao, doc_id, dados) values ('tarefas', 'invasor', '{}');
        raise exception 'FALHOU: pessoa de fora gravou no time';
  exception when insufficient_privilege then null; end;
end $$;

-- anon não lê nada
reset role; set local role anon;
do $$ begin
  begin perform 1 from public.central_docs_historico; raise exception 'FALHOU: anon leu o histórico';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.central_lixeira; raise exception 'FALHOU: anon leu a lixeira';
  exception when insufficient_privilege then null; end;
end $$;
rollback;

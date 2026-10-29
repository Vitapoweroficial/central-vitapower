-- Regras de acesso que já estão em produção (001_central.sql): time vê o que é do time, pessoal só do dono, fora do time nada.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
grant usage on schema t to authenticated; grant execute on all functions in schema t to authenticated;
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com'),
  ('dddddddd-0000-0000-0000-000000000004', 'consultor@outra.com');
insert into public.central_membros (email) values ('consultor@outra.com');
set local role authenticated;

select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
insert into public.central_docs (colecao, doc_id, dados) values ('tarefas', 't1', '{"titulo":"Do time"}');
insert into public.central_docs (colecao, doc_id, dados) values ('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'p1', '{"titulo":"Só meu"}');
select t.ok((select atualizado_por from public.central_docs where doc_id = 't1') = 'aaaaaaaa-0000-0000-0000-000000000001', 'grava quem alterou');
do $$ begin
  begin insert into public.central_docs (colecao, doc_id, dados) values ('pessoal:bbbbbbbb-0000-0000-0000-000000000002', 'p2', '{}');
        raise exception 'FALHOU: gravou no pessoal de outra pessoa';
  exception when insufficient_privilege then null; end;
  begin insert into public.central_docs (colecao, doc_id, dados) values ('qualquer', 'z', '{}');
        raise exception 'FALHOU: aceitou coleção desconhecida';
  exception when check_violation then null; end;
end $$;

select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.ok((select count(*) from public.central_docs where doc_id = 't1') = 1, 'colega vê tarefa do time');
select t.ok((select count(*) from public.central_docs where colecao like 'pessoal:%') = 0, 'colega não vê pessoal de outro');
update public.central_docs set dados = '{"x":1}' where doc_id = 'p1';
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.ok((select dados->>'titulo' from public.central_docs where doc_id = 'p1') = 'Só meu', 'colega não altera pessoal de outro');

select t.como('dddddddd-0000-0000-0000-000000000004', 'consultor@outra.com');
select t.ok((select count(*) from public.central_docs where doc_id = 't1') = 1, 'e-mail liberado em central_membros entra');

select t.como('cccccccc-0000-0000-0000-000000000003', 'x@gmail.com');
select t.ok((select count(*) from public.central_docs) = 0, 'fora do time não lê nada');
select t.ok((select count(*) from public.central_perfis) = 0, 'fora do time não vê perfis');
update public.central_docs set dados = '{}' where doc_id = 't1';
delete from public.central_docs where doc_id = 't1';
do $$ begin
  begin insert into public.central_perfis (id, nome) values ('cccccccc-0000-0000-0000-000000000003', 'Intruso');
        raise exception 'FALHOU: pessoa de fora criou perfil';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select t.ok((select dados->>'titulo' from public.central_docs where doc_id = 't1') = 'Do time', 'fora do time não altera nem exclui');
rollback;

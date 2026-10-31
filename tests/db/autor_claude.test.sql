-- Versão Claude: grava pelo conector (papel do servidor), mas se apresenta como o dono na mesma instrução,
-- para o histórico e as notificações saberem quem fez. Sem se apresentar, continua gravando sem autor.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
-- como o app da versão Claude faz: a apresentação vale só para esta instrução
with eu as (select set_config('request.jwt.claims', json_build_object('sub', u.id, 'email', u.email)::text, true)
              from auth.users u where u.id = 'aaaaaaaa-0000-0000-0000-000000000001')
select public.central_gravar('tarefas', 't1', '{"tipo":"tarefa","titulo":"Laudo","respId":"bbbbbbbb-0000-0000-0000-000000000002"}') from eu;
select t.ok((select por from public.central_docs_historico where doc_id = 't1' order by id desc limit 1) = 'aaaaaaaa-0000-0000-0000-000000000001', 'histórico com autor');
select t.ok((select por from public.central_notificacoes where doc_id = 't1') = 'aaaaaaaa-0000-0000-0000-000000000001', 'aviso diz quem atribuiu');
-- pessoal do dono continua gravando
with eu as (select set_config('request.jwt.claims', json_build_object('sub', u.id, 'email', u.email)::text, true)
              from auth.users u where u.id = 'aaaaaaaa-0000-0000-0000-000000000001')
select public.central_gravar('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'p1', '{"tipo":"tarefa","titulo":"Minha"}') from eu;
select t.ok(exists (select 1 from public.central_tarefas where id = 'p1' and dono = 'aaaaaaaa-0000-0000-0000-000000000001'), 'pessoal gravado');
-- tarefa ligada a outra pessoa: um comentário do dono avisa a responsável, não ele mesmo
with eu as (select set_config('request.jwt.claims', json_build_object('sub', u.id, 'email', u.email)::text, true)
              from auth.users u where u.id = 'aaaaaaaa-0000-0000-0000-000000000001')
select public.central_gravar('tarefas', 't1', (select dados from public.central_itens where doc_id = 't1') || '{"comentarios":[{"id":"c1","texto":"ok?"}]}') from eu;
select t.ok(not exists (select 1 from public.central_notificacoes where usuario = 'aaaaaaaa-0000-0000-0000-000000000001'), 'dono não é avisado do que fez');
-- (no Supabase cada instrução do conector é uma transação, então a apresentação acaba com ela; aqui limpamos à mão)
select set_config('request.jwt.claims', '', true);
select public.central_gravar('tarefas', 't2', '{"tipo":"tarefa","titulo":"Servidor"}');
select t.ok((select por from public.central_docs_historico where doc_id = 't2') is null, 'sem apresentação: grava como servidor');
rollback;

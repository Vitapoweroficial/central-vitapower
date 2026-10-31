-- Anexos (010): quem vê o item vê os anexos; quem edita anexa; pessoal só para o dono; nada se apaga.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
create function t.envia(caminho text) returns boolean language plpgsql as $$
begin insert into storage.objects (bucket_id, name) values ('central-anexos', caminho); return true;
exception when insufficient_privilege then return false; end $$;
create function t.ve(caminho text) returns boolean language sql as $$
  select exists (select 1 from storage.objects where bucket_id = 'central-anexos' and name = caminho) $$;
grant usage on schema t to authenticated; grant execute on all functions in schema t to authenticated;
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'c@vitapowernutrition.com.br'),
  ('dddddddd-0000-0000-0000-000000000004', 'x@gmail.com');
insert into storage.buckets (id, name) values ('outro', 'outro');
select t.ok((select not public and file_size_limit = 26214400 from storage.buckets where id = 'central-anexos'), 'bucket privado com limite de 25 MB');
set local role authenticated;
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('projetos', 'pr', '{"nome":"Secreto","acesso":"restrito","membros":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","papel":"dono"},{"id":"bbbbbbbb-0000-0000-0000-000000000002","papel":"leitor"}]}');
select public.central_gravar('tarefas', 'tt', '{"tipo":"tarefa","titulo":"Laudo"}');
select public.central_gravar('tarefas', 'ts', '{"tipo":"tarefa","titulo":"Fórmula","projetoId":"pr"}');
select public.central_gravar('paginas', 'pg', '{"tipo":"pagina","titulo":"POP"}');
select public.central_gravar('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'mp', '{"tipo":"tarefa","titulo":"Minha"}');
select t.ok(t.envia('tarefas/tt/1-laudo.pdf'), 'anexa em tarefa do time');
select t.ok(t.envia('tarefas/ts/2-formula.pdf'), 'dono do projeto anexa');
select t.ok(t.envia('paginas/pg/3-foto.jpg'), 'anexa em página');
select t.ok(t.envia('pessoal-aaaaaaaa-0000-0000-0000-000000000001/mp/4-meu.pdf'), 'anexa em item pessoal');
select t.ok(not t.envia('tarefas/mp/5-x.pdf'), 'tarefa pessoal não aceita caminho do time');
select t.ok(not t.envia('tarefas/tt'), 'caminho incompleto recusado');
select t.ok(not t.envia('projetos/pr/6-x.pdf'), 'coleção sem anexos recusada');
-- B: leitor no projeto restrito
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select t.ok(t.ve('tarefas/tt/1-laudo.pdf') and t.ve('paginas/pg/3-foto.jpg'), 'colega vê anexos do time');
select t.ok(t.ve('tarefas/ts/2-formula.pdf'), 'leitor do projeto vê');
select t.ok(not t.envia('tarefas/ts/7-x.pdf'), 'leitor não anexa');
select t.ok(not t.ve('pessoal-aaaaaaaa-0000-0000-0000-000000000001/mp/4-meu.pdf'), 'não vê anexo pessoal de outra pessoa');
select t.ok(not t.envia('pessoal-aaaaaaaa-0000-0000-0000-000000000001/mp/8-x.pdf'), 'não anexa no pessoal de outra pessoa');
-- C: fora do projeto restrito
select t.como('cccccccc-0000-0000-0000-000000000003', 'c@vitapowernutrition.com.br');
select t.ok(not t.ve('tarefas/ts/2-formula.pdf') and t.ve('tarefas/tt/1-laudo.pdf'), 'fora do projeto não vê o anexo dele');
-- X: de fora da empresa
select t.como('dddddddd-0000-0000-0000-000000000004', 'x@gmail.com');
select t.ok(not t.ve('tarefas/tt/1-laudo.pdf') and not t.envia('tarefas/tt/9-x.pdf'), 'quem é de fora não vê nem anexa');
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.ok(not t.envia('outro/qualquer/coisa'), 'nada muda nos outros buckets');
-- nada se apaga nem se substitui
do $$ begin update storage.objects set name = 'x' where bucket_id = 'central-anexos'; raise exception 'FALHOU: atualizou';
exception when insufficient_privilege then null; end $$;
do $$ begin delete from storage.objects where bucket_id = 'central-anexos'; raise exception 'FALHOU: apagou';
exception when insufficient_privilege then null; end $$;
reset role;
rollback;

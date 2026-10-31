-- Automações (009): lembretes de prazo, atraso e aprovação parada; uma vez por dia; respeitam quem pode ver.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
create function t.n(u text, tipo text, doc text) returns int language sql as $$
  select count(*)::int from public.central_notificacoes where usuario = u::uuid and tipo = $2 and doc_id = doc $$;
grant usage on schema t to authenticated; grant execute on all functions in schema t to authenticated;
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'c@vitapowernutrition.com.br');
set local role authenticated;
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
-- vence em 10/11 (B responde), venceu em 09/11 (sem responsável: lembra quem criou), concluída, pessoal, e de projeto restrito
select public.central_gravar('tarefas', 'hoje', '{"tipo":"tarefa","titulo":"Laudo","prazo":"2026-11-10","criadoPor":"aaaaaaaa-0000-0000-0000-000000000001","respId":"bbbbbbbb-0000-0000-0000-000000000002"}');
select public.central_gravar('tarefas', 'ontem', '{"tipo":"tarefa","titulo":"Rótulo","prazo":"2026-11-09","criadoPor":"aaaaaaaa-0000-0000-0000-000000000001"}');
select public.central_gravar('tarefas', 'feita', '{"tipo":"tarefa","titulo":"Ok","prazo":"2026-11-10","status":"feito","respId":"bbbbbbbb-0000-0000-0000-000000000002"}');
select public.central_gravar('pessoal:aaaaaaaa-0000-0000-0000-000000000001', 'minha', '{"tipo":"tarefa","titulo":"Minha","prazo":"2026-11-10"}');
select public.central_gravar('projetos', 'pr', '{"nome":"Secreto","acesso":"restrito","membros":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","papel":"editor"}]}');
select public.central_gravar('tarefas', 'sec', '{"tipo":"tarefa","titulo":"Fórmula","prazo":"2026-11-10","projetoId":"pr","respId":"cccccccc-0000-0000-0000-000000000003"}');
select public.central_gravar('paginas', 'pop', '{"tipo":"pagina","titulo":"POP","conteudo":"<p>x</p>","estado":"revisao","aprovacoes":[{"id":"ap1","por":"cccccccc-0000-0000-0000-000000000003","status":"pendente","pedidoPor":"aaaaaaaa-0000-0000-0000-000000000001","pedidoEm":"2026-11-08T13:00:00Z"}]}');
-- ninguém do app roda os lembretes
do $$ begin perform central_priv.lembretes('2026-11-10'); raise exception 'FALHOU: rodou como usuário';
exception when insufficient_privilege then null; end $$;
reset role;
delete from public.central_notificacoes;
select t.ok(central_priv.lembretes('2026-11-10') = 3, 'três lembretes no dia');
select t.ok(t.n('bbbbbbbb-0000-0000-0000-000000000002', 'prazo', 'hoje') = 1, 'responsável lembrada do prazo');
select t.ok(t.n('aaaaaaaa-0000-0000-0000-000000000001', 'atrasada', 'ontem') = 1, 'sem responsável, quem criou é lembrado do atraso');
select t.ok(t.n('cccccccc-0000-0000-0000-000000000003', 'lembrete_aprovacao', 'pop') = 1, 'aprovação parada há 2 dias lembra');
select t.ok((select count(*) from public.central_notificacoes where doc_id in ('feita','minha','sec')) = 0, 'concluída, pessoal e projeto sem acesso não lembram');
select t.ok((select por is null from public.central_notificacoes where doc_id = 'hoje'), 'lembrete vem do sistema');
select t.ok(central_priv.lembretes('2026-11-10') = 0, 'rodar de novo no mesmo dia não repete');
select t.ok(central_priv.lembretes('2026-11-11') = 1 and t.n('bbbbbbbb-0000-0000-0000-000000000002', 'atrasada', 'hoje') = 1, 'no dia seguinte, o prazo de ontem vira atraso');
select t.ok(central_priv.lembretes('2026-11-13') = 1 and t.n('cccccccc-0000-0000-0000-000000000003', 'lembrete_aprovacao', 'pop') = 2, 'aprovação parada lembra de novo depois de 3 dias');
select t.ok(central_priv.lembretes('2026-11-16') = 1, 'só o lembrete de aprovação');
select t.ok(central_priv.lembretes('2026-11-17') = 1 and t.n('aaaaaaaa-0000-0000-0000-000000000001', 'atrasada', 'ontem') = 2, 'atraso repete uma semana depois');
rollback;

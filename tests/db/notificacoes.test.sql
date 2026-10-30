-- Notificações (008): atribuição, comentário, menção, conclusão, aprovação, projeto; ninguém lê o aviso dos outros.
begin;
create schema t;
create function t.ok(cond boolean, nome text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FALHOU: %', nome; end if; end $$;
create function t.como(uid text, email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'email', email)::text, true) $$;
create function t.doc(id text) returns jsonb language sql as $$ select dados from public.central_itens where doc_id = id $$;
-- conta avisos direto na tabela (sem RLS), para conferir também o que outra pessoa recebeu
create function t.n(u text, tipo text, doc text) returns int language sql security definer as $$
  select count(*)::int from public.central_notificacoes where usuario = u::uuid and tipo = $2 and doc_id = doc $$;
create function t.naolidas(u text) returns int language sql security definer as $$
  select count(*)::int from public.central_notificacoes where usuario = u::uuid and lida_em is null $$;
grant usage on schema t to authenticated, anon; grant execute on all functions in schema t to authenticated, anon;
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br'),
  ('cccccccc-0000-0000-0000-000000000003', 'c@vitapowernutrition.com.br');
set local role authenticated;

-- A cria tarefa e atribui a B: B é avisada; A não recebe aviso do que fez
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('tarefas', 't1', '{"tipo":"tarefa","titulo":"Pesar lote 12","criadoPor":"aaaaaaaa-0000-0000-0000-000000000001","respId":"bbbbbbbb-0000-0000-0000-000000000002"}');
select t.ok(t.n('bbbbbbbb-0000-0000-0000-000000000002', 'atribuida', 't1') = 1, 'responsável é avisada');
select t.ok(t.n('aaaaaaaa-0000-0000-0000-000000000001', 'atribuida', 't1') = 0, 'quem fez não é avisado');
-- regravar sem trocar o responsável não repete o aviso
select public.central_gravar('tarefas', 't1', t.doc('t1') || '{"prioridade":"alta"}');
select t.ok(t.n('bbbbbbbb-0000-0000-0000-000000000002', 'atribuida', 't1') = 1, 'sem aviso repetido');

-- B comenta e menciona C: C recebe menção, A (quem criou) recebe comentário
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select public.central_gravar('tarefas', 't1', t.doc('t1') || '{"comentarios":[{"id":"c1","por":"bbbbbbbb-0000-0000-0000-000000000002","texto":"@C confere a balança?","mencoes":["cccccccc-0000-0000-0000-000000000003"]}]}');
select t.ok(t.n('cccccccc-0000-0000-0000-000000000003', 'mencao', 't1') = 1, 'mencionada é avisada');
select t.ok(t.n('aaaaaaaa-0000-0000-0000-000000000001', 'comentario', 't1') = 1, 'quem criou é avisada do comentário');
select t.ok(t.n('bbbbbbbb-0000-0000-0000-000000000002', 'comentario', 't1') = 0, 'quem comentou não é avisada');
-- regravar a tarefa com o mesmo comentário não avisa de novo
select public.central_gravar('tarefas', 't1', t.doc('t1') || '{"descricao":"x"}');
select t.ok(t.n('cccccccc-0000-0000-0000-000000000003', 'mencao', 't1') = 1, 'comentário antigo não avisa de novo');

-- B conclui: A é avisada
select public.central_gravar('tarefas', 't1', t.doc('t1') || '{"status":"feito"}');
select t.ok(t.n('aaaaaaaa-0000-0000-0000-000000000001', 'concluida', 't1') = 1, 'quem criou é avisada da conclusão');

-- cada um só lê e marca os próprios avisos
select t.ok((select count(*) from public.central_notificacoes) = 1, 'B lê só os avisos dela');
select t.ok((select bool_and(usuario = 'bbbbbbbb-0000-0000-0000-000000000002') from public.central_notificacoes), 'nenhum aviso alheio');
select t.ok(public.central_marcar_lidas() = 1, 'B marca os dela como lidos');
select t.ok(t.naolidas('aaaaaaaa-0000-0000-0000-000000000001') = 2, 'marcar não mexe nos avisos de A');
do $$ begin
  update public.central_notificacoes set lida_em = now();
  raise exception 'FALHOU: atualizou direto';
exception when insufficient_privilege then null; end $$;

-- Projeto restrito: quem entra é avisado; tarefa de projeto restrito não avisa quem está fora
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('projetos', 'p1', '{"nome":"Linha Kids","acesso":"restrito","membros":[{"id":"bbbbbbbb-0000-0000-0000-000000000002","papel":"editor"}]}');
select t.ok(t.n('bbbbbbbb-0000-0000-0000-000000000002', 'projeto', 'p1') = 1, 'quem entra no projeto é avisada');
select public.central_gravar('tarefas', 't2', '{"tipo":"tarefa","titulo":"Fórmula secreta","projetoId":"p1","respId":"cccccccc-0000-0000-0000-000000000003"}');
select t.ok(t.n('cccccccc-0000-0000-0000-000000000003', 'atribuida', 't2') = 0, 'quem não vê o projeto não recebe aviso');

-- Página: pedido de aprovação, resposta e menção no texto
select public.central_gravar('paginas', 'pop', '{"tipo":"pagina","titulo":"POP","conteudo":"<p>oi <span class=\"mencao\" data-mencao=\"cccccccc-0000-0000-0000-000000000003\">@C</span></p>","estado":"revisao","aprovacoes":[{"id":"ap1","por":"bbbbbbbb-0000-0000-0000-000000000002","status":"pendente","pedidoPor":"aaaaaaaa-0000-0000-0000-000000000001"}]}');
select t.ok(t.n('bbbbbbbb-0000-0000-0000-000000000002', 'aprovacao', 'pop') = 1, 'aprovadora é avisada do pedido');
select t.ok(t.n('cccccccc-0000-0000-0000-000000000003', 'mencao', 'pop') = 1, 'menção no texto avisa');
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select public.central_gravar('paginas', 'pop', t.doc('pop') || '{"estado":"aprovado","aprovacoes":[{"id":"ap1","por":"bbbbbbbb-0000-0000-0000-000000000002","status":"aprovado","pedidoPor":"aaaaaaaa-0000-0000-0000-000000000001"}]}');
select t.ok(t.n('aaaaaaaa-0000-0000-0000-000000000001', 'aprovacao_resposta', 'pop') = 1, 'quem pediu é avisada da resposta');
select t.ok(t.n('cccccccc-0000-0000-0000-000000000003', 'mencao', 'pop') = 1, 'menção antiga não repete');

-- Itens pessoais não geram aviso
select public.central_gravar('pessoal:bbbbbbbb-0000-0000-0000-000000000002', 'tp', '{"tipo":"tarefa","titulo":"minha","respId":"aaaaaaaa-0000-0000-0000-000000000001"}');
select t.ok(t.n('aaaaaaaa-0000-0000-0000-000000000001', 'atribuida', 'tp') = 0, 'pessoal não avisa');
rollback;

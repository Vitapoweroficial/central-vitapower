-- Documentos (007): estado, aprovações de cada pessoa e trava da versão aprovada.
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
create function t.pg() returns jsonb language sql as $$ select dados from public.central_itens where doc_id = 'pop' $$;
grant usage on schema t to authenticated, anon; grant execute on all functions in schema t to authenticated, anon;
insert into auth.users values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
set local role authenticated;

-- A escreve o POP e pede aprovação a B
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select public.central_gravar('paginas', 'pop', '{"tipo":"pagina","titulo":"POP Limpeza","conteudo":"<p>v1</p>"}');
select public.central_gravar('paginas', 'pop', t.pg() || '{"estado":"revisao","aprovacoes":[{"id":"ap1","por":"bbbbbbbb-0000-0000-0000-000000000002","status":"pendente"}]}');
select t.ok(t.pg()->>'estado' = 'revisao', 'estado fica guardado');
-- A não pode aprovar no lugar de B, nem marcar como aprovado sem a aprovação dela
select t.erro($$select public.central_gravar('paginas', 'pop', t.pg() || '{"aprovacoes":[{"id":"ap1","por":"bbbbbbbb-0000-0000-0000-000000000002","status":"aprovado"}]}')$$, '42501', 'ninguém aprova pela outra pessoa');
select t.erro($$select public.central_gravar('paginas', 'pop', t.pg() || '{"estado":"aprovado"}')$$, '42501', 'não fica aprovado com aprovação pendente');

-- B aprova: o documento fica aprovado
select t.como('bbbbbbbb-0000-0000-0000-000000000002', 'b@vitapowernutrition.com.br');
select public.central_gravar('paginas', 'pop', t.pg() || '{"estado":"aprovado","aprovacoes":[{"id":"ap1","por":"bbbbbbbb-0000-0000-0000-000000000002","status":"aprovado"}]}');
select t.ok(t.pg()->>'estado' = 'aprovado', 'aprovado depois da aprovação de B');

-- Versão aprovada não muda; para mudar, abre nova revisão
select t.como('aaaaaaaa-0000-0000-0000-000000000001', 'a@vitapowernutrition.com.br');
select t.erro($$select public.central_gravar('paginas', 'pop', t.pg() || '{"conteudo":"<p>v2</p>"}')$$, '42501', 'versão aprovada não pode ser editada');
select public.central_gravar('paginas', 'pop', (t.pg() - 'aprovacoes') || '{"estado":"rascunho"}');
select public.central_gravar('paginas', 'pop', t.pg() || '{"conteudo":"<p>v2</p>"}');
select t.ok(t.pg()->>'conteudo' = '<p>v2</p>', 'nova revisão pode ser editada');
select t.ok(exists (select 1 from public.central_docs_historico where doc_id = 'pop' and dados->>'estado' = 'aprovado' and dados->>'conteudo' = '<p>v1</p>'),
  'versão aprovada continua no histórico');
select t.erro($$select public.central_gravar('paginas', 'pop', t.pg() || '{"aprovacoes":{"x":1}}')$$, '22023', 'aprovações têm de ser lista');
rollback;

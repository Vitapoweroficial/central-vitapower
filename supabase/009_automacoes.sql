-- Central: automações (backlog item 12). Todo dia às 8h (horário de Brasília) o banco gera lembretes:
--   - "prazo": a tarefa do time vence hoje (para quem responde; sem responsável, para quem criou);
--   - "atrasada": a tarefa venceu ontem e não foi concluída (repete a cada 7 dias enquanto continuar atrasada);
--   - "lembrete_aprovacao": um pedido de aprovação de documento está parado há 2 dias (repete a cada 3 dias).
-- Os lembretes entram na mesma lista de notificações (008), com "por" vazio, e respeitam quem pode ver o item.
-- Rodar duas vezes no mesmo dia não duplica nada. Itens pessoais não geram lembretes.
-- O agendamento usa o pg_cron do Supabase (gratuito, já instalado). Só acrescenta; nada é apagado.
-- Depende de 008_notificacoes.sql.

-- Os tipos novos de aviso
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'public.central_notificacoes'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%tipo%' loop
    execute format('alter table public.central_notificacoes drop constraint %I', c);
  end loop;
end $$;
alter table public.central_notificacoes add constraint central_notificacoes_tipo_check check (tipo in
  ('atribuida','comentario','mencao','concluida','aprovacao','aprovacao_resposta','projeto','prazo','atrasada','lembrete_aprovacao'));

-- Dia a que o lembrete se refere (evita repetir o mesmo lembrete no mesmo dia)
alter table public.central_notificacoes add column dia date;

-- Grava um lembrete, uma vez por dia por pessoa, tipo e item, se a pessoa pode ver o item
create or replace function central_priv.lembrar(p_usuario uuid, p_tipo text, p_colecao text, p_doc text, p_titulo text,
  p_trecho text, p_projeto text, p_dia date) returns integer
language plpgsql security definer set search_path = '' as $$
begin
  if p_usuario is null or not central_priv.ve_projeto_de(p_projeto, p_usuario) then return 0; end if;
  if exists (select 1 from public.central_notificacoes n where n.usuario = p_usuario and n.tipo = p_tipo
             and n.colecao = p_colecao and n.doc_id = p_doc and n.dia = p_dia) then
    return 0;
  end if;
  insert into public.central_notificacoes (usuario, tipo, colecao, doc_id, titulo, trecho, por, dia)
  values (p_usuario, p_tipo, p_colecao, p_doc, left(coalesce(p_titulo, ''), 200), left(p_trecho, 280), null, p_dia);
  return 1;
end $$;
revoke all on function central_priv.lembrar(uuid, text, text, text, text, text, text, date) from public, anon, authenticated;

-- Gera os lembretes do dia; devolve quantos foram criados
create or replace function central_priv.lembretes(p_dia date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  dia date := coalesce(p_dia, (now() at time zone 'America/Sao_Paulo')::date);
  n integer := 0; r record; a jsonb;
begin
  for r in select t.id, t.titulo, t.prazo, t.projeto_id,
                  coalesce(central_priv.uuid_ou_nulo(t.resp_id), central_priv.uuid_ou_nulo(t.criado_por)) as quem
             from public.central_tarefas t
            where not t.privada and t.excluido_em is null and t.status <> 'feito' and t.arquivado is not true
              and t.prazo is not null and t.prazo <= dia loop
    if r.prazo = dia then
      n := n + central_priv.lembrar(r.quem, 'prazo', 'tarefas', r.id, r.titulo, null, r.projeto_id, dia);
    elsif (dia - r.prazo) % 7 = 1 then
      n := n + central_priv.lembrar(r.quem, 'atrasada', 'tarefas', r.id, r.titulo,
                 case when dia - r.prazo = 1 then 'venceu ontem' else format('atrasada há %s dias', dia - r.prazo) end, r.projeto_id, dia);
    end if;
  end loop;
  for r in select p.id, p.titulo, p.extras->'aprovacoes' as aps
             from public.central_paginas p
            where not p.privada and p.excluido_em is null and jsonb_typeof(p.extras->'aprovacoes') = 'array' loop
    for a in select x from jsonb_array_elements(r.aps) x loop
      continue when coalesce(a->>'status', 'pendente') <> 'pendente' or a->>'pedidoEm' is null;
      declare espera integer := dia - ((a->>'pedidoEm')::timestamptz at time zone 'America/Sao_Paulo')::date;
      begin
        if espera >= 2 and (espera - 2) % 3 = 0 then
          n := n + central_priv.lembrar(central_priv.uuid_ou_nulo(a->>'por'), 'lembrete_aprovacao', 'paginas', r.id, r.titulo,
                     format('esperando há %s dias', espera), null, dia);
        end if;
      exception when invalid_datetime_format or datetime_field_overflow then null;
      end;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function central_priv.lembretes(date) from public, anon, authenticated;

-- Agenda: todo dia às 11:00 UTC = 8:00 em Brasília. (Sem pg_cron, como no teste local, só não agenda.)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('central-lembretes', '0 11 * * *', 'select central_priv.lembretes()');
  end if;
end $$;

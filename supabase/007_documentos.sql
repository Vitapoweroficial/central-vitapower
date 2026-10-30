-- Central: documentos com estado e aprovações (backlog itens 9, 10 e 15).
-- Uma página pode estar em rascunho, em revisão, aprovada ou obsoleta (campo "estado") e ter aprovações pedidas
-- a pessoas do time (campo "aprovacoes": [{id, por, status: pendente|aprovado|ajustes, em, pedidoPor, pedidoEm}]).
-- O banco garante, para quem usa o app:
--   - página aprovada ou obsoleta não muda de título nem de texto: para mudar, abre-se uma nova revisão (volta a rascunho),
--     e a versão aprovada continua no histórico;
--   - cada pessoa só registra a própria aprovação;
--   - a página só fica aprovada quando todas as aprovações pedidas foram dadas.
-- Os dois campos ficam em "extras" (nenhuma coluna nova). Só acrescenta um gatilho; nada é apagado.
-- Depende de 006_permissoes.sql.

create or replace function central_priv.conferir_documento() returns trigger
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); e jsonb; o jsonb; antes jsonb;
begin
  if coalesce(central_priv.e_servidor(), false) then return new; end if;
  antes := case when tg_op = 'UPDATE' then coalesce(old.extras->'aprovacoes', '[]') else '[]' end;

  if tg_op = 'UPDATE' and new.excluido_em is null and old.extras->>'estado' in ('aprovado','obsoleto')
     and coalesce(new.extras->>'estado', 'rascunho') = old.extras->>'estado'
     and (new.titulo is distinct from old.titulo or new.conteudo is distinct from old.conteudo) then
    raise exception 'documento % não pode ser alterado; abra uma nova revisão', old.extras->>'estado' using errcode = '42501';
  end if;

  if new.extras ? 'aprovacoes' and jsonb_typeof(new.extras->'aprovacoes') <> 'array' then
    raise exception 'aprovacoes deve ser uma lista' using errcode = '22023';
  end if;
  for e in select x from jsonb_array_elements(coalesce(new.extras->'aprovacoes', '[]')) x loop
    o := (select y from jsonb_array_elements(antes) y where y->>'id' = e->>'id');
    if coalesce(e->>'status', 'pendente') <> 'pendente'
       and coalesce(o->>'status', 'pendente') is distinct from e->>'status'
       and e->>'por' is distinct from uid::text then
      raise exception 'só a própria pessoa registra a aprovação dela' using errcode = '42501';
    end if;
  end loop;

  if new.extras->>'estado' = 'aprovado' and (tg_op = 'INSERT' or old.extras->>'estado' is distinct from 'aprovado') then
    if jsonb_array_length(coalesce(new.extras->'aprovacoes', '[]')) = 0
       or exists (select 1 from jsonb_array_elements(new.extras->'aprovacoes') x where x->>'status' is distinct from 'aprovado') then
      raise exception 'o documento só fica aprovado depois de todas as aprovações pedidas' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function central_priv.conferir_documento() from public, anon, authenticated;
create trigger central_documento before insert or update on public.central_paginas
  for each row execute function central_priv.conferir_documento();

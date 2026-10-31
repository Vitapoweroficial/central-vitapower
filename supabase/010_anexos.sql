-- Central: anexos de arquivos (PDF, foto, laudo, cotação) em tarefas e páginas.
-- Os arquivos ficam no Storage do Supabase, num "bucket" privado só da Central: "central-anexos".
-- Caminho de cada arquivo: <coleção>/<id do item>/<id do anexo>-<nome>
--   coleção = "tarefas", "paginas" ou "pessoal-<id da pessoa>" (itens "Só eu").
-- Quem vê o item vê (e baixa) os anexos; quem pode editar o item pode anexar.
-- Nada é apagado nem substituído: não há permissão de excluir ou sobrescrever arquivos.
-- A lista de anexos de cada item fica no próprio item (campo "anexos"), como os links.
-- Limite de 25 MB por arquivo. O plano gratuito do Supabase inclui 1 GB de Storage no total.
-- Depende de 006_permissoes.sql. Não mexe em nenhum outro bucket.

insert into storage.buckets (id, name, public, file_size_limit)
values ('central-anexos', 'central-anexos', false, 26214400)
on conflict (id) do nothing;

-- A pessoa logada pode ler (p_escrever = false) ou anexar (true) neste caminho?
create or replace function central_priv.anexo_ok(p_nome text, p_escrever boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  parte text[] := string_to_array(p_nome, '/');
  col text := parte[1];
  doc text := parte[2];
  t record;
begin
  if coalesce(array_length(parte, 1), 0) <> 3 or coalesce(col, '') = '' or coalesce(doc, '') = '' or coalesce(parte[3], '') = '' then
    return false;
  end if;
  if col like 'pessoal-%' then
    return (select auth.uid()) is not null and substr(col, 9) = (select auth.uid())::text;
  end if;
  if not (select central_priv.e_membro()) then return false; end if;
  if col = 'paginas' then
    return not exists (select 1 from public.central_paginas g where g.id = doc and g.privada);
  elsif col = 'tarefas' then
    select tt.privada, tt.projeto_id into t from public.central_tarefas tt where tt.id = doc;
    if not found then return true; end if;   -- tarefa nova, ainda sendo gravada
    if t.privada then return false; end if;
    return case when p_escrever then coalesce(central_priv.papel_projeto(t.projeto_id), 'leitor') in ('dono', 'editor')
                else central_priv.papel_projeto(t.projeto_id) is not null end;
  end if;
  return false;
end $$;
revoke all on function central_priv.anexo_ok(text, boolean) from public, anon;
grant execute on function central_priv.anexo_ok(text, boolean) to authenticated;

drop policy if exists "central anexos ler" on storage.objects;
create policy "central anexos ler" on storage.objects for select to authenticated
  using (bucket_id = 'central-anexos' and central_priv.anexo_ok(name, false));
drop policy if exists "central anexos enviar" on storage.objects;
create policy "central anexos enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'central-anexos' and central_priv.anexo_ok(name, true));

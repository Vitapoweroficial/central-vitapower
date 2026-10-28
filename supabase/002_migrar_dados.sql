-- Copia os dados do app antigo (cópia de segurança em vita_tarefas.documentos) para a Central.
-- Itens pessoais pertenciam ao dono da página (Andrew). Não altera nem apaga a cópia antiga.
insert into public.central_docs (colecao, doc_id, dados)
select case when d.colecao = 'pessoal' then 'pessoal:' || u.id::text else d.colecao end, d.doc_id, d.dados
from vita_tarefas.documentos d
cross join (select id from auth.users where email = 'andrew@vitapowernutrition.com.br') u
where not coalesce(d.excluido, false)
  and d.colecao in ('tarefas','projetos','paginas','config','pessoal')
on conflict (colecao, doc_id) do nothing;

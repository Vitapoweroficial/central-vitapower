# Central VitaPower

App de tarefas, projetos e páginas do time VitaPower. Login por e-mail (link de acesso), dados no Supabase com atualização em tempo real, assistente com Claude e instalável no celular (PWA).

## Como está montado

- `public/index.html`: a interface do app (a mesma que rodava no Claude).
- `public/central.js`: login e acesso aos dados no Supabase. Entrega ao app as mesmas funções de dados, pessoas e assistente que ele usava antes.
- `api/assistente.js`: função na Vercel que confere se a pessoa é do time e chama o Claude.
- `supabase/`: SQL das tabelas (`central_docs`, `central_perfis`, `central_membros`), da cópia dos dados antigos e do histórico de versões e lixeira (`003_historico.sql`: `central_docs_historico`, gravado por trigger, e a visão `central_lixeira`).
- `tests/`: testes de banco (`tests/db`, sobem um Postgres local e conferem RLS, histórico e lixeira) e de interface (`tests/e2e`, abrem o app num Chromium com um banco falso).

## Quem tem acesso

Qualquer e-mail `@vitapowernutrition.com.br`, mais os e-mails cadastrados na tabela `central_membros`.
O assistente aparece só para os e-mails em `ASSISTENTE_EMAILS` (variável na Vercel, separados por vírgula; `*` libera para todos). Sem essa variável, só o Andrew.
Itens marcados "Só eu" ficam visíveis apenas para quem os criou.

## Configuração

1. Supabase → Authentication → URL Configuration: incluir o endereço da Vercel em **Redirect URLs** (ex.: `https://central-vitapower.vercel.app/**`).
2. Vercel → Settings → Environment Variables: criar `ANTHROPIC_API_KEY` com a chave do Claude (console.anthropic.com). Nunca colocar a chave no código.
3. Publicar: a Vercel publica sozinha a cada push na branch principal.

## Histórico e lixeira

Depois de aplicar `supabase/003_historico.sql`, toda criação, alteração e exclusão vira uma versão guardada pelo próprio banco.
No app aparecem o item **Lixeira** no menu e o botão **Versões** em tarefas, projetos e páginas. Sem a migração aplicada, o app funciona como antes e esconde esses botões.

## Testes

```
npm test            # os dois abaixo
npm run test:db     # precisa do PostgreSQL 15+ instalado; não toca no Supabase
npm run test:e2e    # precisa do Playwright com Chromium
```

# Central VitaPower

App de tarefas, projetos e páginas do time VitaPower. Login por e-mail (link de acesso), dados no Supabase com atualização em tempo real, assistente com Claude e instalável no celular (PWA).

## Como está montado

- `public/index.html`: a interface do app (a mesma que rodava no Claude).
- `public/central.js`: login e acesso aos dados no Supabase. Entrega ao app as mesmas funções de dados, pessoas e assistente que ele usava antes.
- `api/assistente.js`: função na Vercel que confere se a pessoa é do time e chama o Claude.
- `supabase/`: SQL das tabelas (`central_docs`, `central_perfis`, `central_membros`) e da cópia dos dados antigos.

## Quem tem acesso

Qualquer e-mail `@vitapowernutrition.com.br`, mais os e-mails cadastrados na tabela `central_membros`.
Itens marcados "Só eu" ficam visíveis apenas para quem os criou.

## Configuração

1. Supabase → Authentication → URL Configuration: incluir o endereço da Vercel em **Redirect URLs** (ex.: `https://central-vitapower.vercel.app/**`).
2. Vercel → Settings → Environment Variables: criar `ANTHROPIC_API_KEY` com a chave do Claude (console.anthropic.com). Nunca colocar a chave no código.
3. Publicar: a Vercel publica sozinha a cada push na branch principal.

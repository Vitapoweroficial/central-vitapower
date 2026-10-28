// Assistente da Central: recebe a conversa do app, confere se quem pede é do time e chama o Claude.
import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";

const SB_URL = process.env.SUPABASE_URL || "https://tlbufqzembztbhcfdccg.supabase.co";
const SB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || "sb_publishable_nhB_rsCG-ZEn6we-wVXhEQ_vBzPvU5p";
const MAX_CHARS = 400_000;

const anthropic = new Anthropic();

function falha(res, status, code, message) {
  res.status(status).json({ error: { code, message } });
}

// Junta mensagens seguidas do mesmo papel e garante que a conversa começa pela pessoa
function normalizar(lista) {
  const out = [];
  for (const m of lista) {
    if (!m || (m.role !== "user" && m.role !== "assistant") || typeof m.content !== "string") continue;
    const ult = out[out.length - 1];
    if (ult && ult.role === m.role) ult.content += "\n\n" + m.content;
    else out.push({ role: m.role, content: m.content });
  }
  while (out.length && out[0].role !== "user") out.shift();
  return out;
}

function lerJson(texto) {
  const t = texto.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "");
  try { return JSON.parse(t); } catch {}
  const a = t.indexOf("{"), b = t.lastIndexOf("}");
  if (a >= 0 && b > a) { try { return JSON.parse(t.slice(a, b + 1)); } catch {} }
  return null;
}

export default async function handler(req, res) {
  if (req.method !== "POST") return falha(res, 405, "method", "Use POST");

  const token = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!token) return falha(res, 401, "session_expired", "Entre de novo");
  const sb = createClient(SB_URL, SB_KEY, {
    global: { headers: { Authorization: "Bearer " + token } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: u, error: eu } = await sb.auth.getUser(token);
  if (eu || !u?.user) return falha(res, 401, "session_expired", "Sessão vencida");
  // central_perfis só é visível para quem é do time (RLS)
  const { data: perfil } = await sb.from("central_perfis").select("id").eq("id", u.user.id).maybeSingle();
  if (!perfil) return falha(res, 403, "not_granted", "Conta fora do time");

  const messages = normalizar(Array.isArray(req.body?.messages) ? req.body.messages : []);
  if (!messages.length || messages[messages.length - 1].role !== "user") return falha(res, 400, "invalid_request", "Conversa vazia");
  if (messages.reduce((n, m) => n + m.content.length, 0) > MAX_CHARS) return falha(res, 413, "prompt_too_large", "Dados demais");

  try {
    const r = await anthropic.beta.messages.create({
      model: "claude-opus-5-5",
      max_tokens: 16000,
      thinking: { type: "adaptive" },
      output_config: { effort: "medium" },
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: "Você é o assistente da Central VitaPower. Siga as instruções e o formato pedidos na primeira mensagem e responda somente com o objeto JSON pedido, sem texto antes ou depois.",
      messages,
    });
    if (r.stop_reason === "refusal") return falha(res, 422, "refused", "O assistente não pôde atender este pedido");
    const texto = r.content.filter((b) => b.type === "text").map((b) => b.text).join("");
    const resultado = lerJson(texto);
    if (!resultado || typeof resultado !== "object") return falha(res, 502, "invalid_json", "Resposta fora do formato");
    res.status(200).json({ resultado });
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) return falha(res, 429, "rate_limited", "Limite atingido");
    if (e instanceof Anthropic.AuthenticationError) return falha(res, 500, "not_configured", "Chave do Claude ausente ou inválida na Vercel");
    if (e instanceof Anthropic.APIError) return falha(res, 502, "upstream", "Erro no Claude (" + e.status + ")");
    return falha(res, 500, "erro", "Falha inesperada");
  }
}

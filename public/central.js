/* Central VitaPower: login e dados no Supabase.
   Oferece ao app a mesma interface que ele usava dentro do Claude (window.claude.use: db, user, sample),
   então a interface do app não precisa saber onde os dados ficam. */
(function () {
  const SB_URL = "https://tlbufqzembztbhcfdccg.supabase.co";
  const SB_KEY = "sb_publishable_nhB_rsCG-ZEn6we-wVXhEQ_vBzPvU5p";
  const TIMES = ["tarefas", "projetos", "paginas", "config"];

  const sb = window.supabase.createClient(SB_URL, SB_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: "pkce" },
  });
  window.CENTRAL = { modo: "vercel", sb };

  let uid = null, email = "", meuNome = "";
  let liberar;
  const pronto = new Promise((r) => (liberar = r));

  /* ---------- tela de entrada ---------- */
  const css = `#cx{position:fixed;inset:0;z-index:9999;display:grid;place-items:center;background:#f6f5f2;font:15px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1d1d1f;padding:16px}
#cx .cx-c{width:100%;max-width:380px;background:#fff;border:1px solid #e6e3dc;border-radius:16px;padding:28px 24px;box-shadow:0 8px 30px rgba(0,0,0,.06)}
#cx h1{font-size:20px;margin:0 0 4px}#cx p{margin:0 0 16px;color:#5f5d58}#cx label{display:block;font-size:13px;color:#5f5d58;margin-bottom:4px}
#cx input{width:100%;box-sizing:border-box;font:inherit;padding:11px 12px;border:1px solid #d9d5cc;border-radius:10px;margin-bottom:12px;background:#fff;color:inherit}
#cx button{width:100%;font:inherit;font-weight:600;padding:11px;border:0;border-radius:10px;background:#1f6f54;color:#fff;cursor:pointer}
#cx button:disabled{opacity:.6;cursor:default}#cx .cx-m{font-size:13px;margin-top:12px;min-height:18px;color:#5f5d58}#cx .cx-m.err{color:#b3261e}
#cx .cx-l{background:none;color:#1f6f54;padding:6px;margin-top:6px;font-weight:500}
@media (prefers-color-scheme:dark){#cx{background:#161615;color:#eee}#cx .cx-c{background:#1f1f1e;border-color:#333}#cx input{background:#161615;border-color:#3a3a38}#cx p,#cx label,#cx .cx-m{color:#aaa}}
button.cx-sair{display:block;margin-top:2px;font-size:12px;color:inherit;opacity:.7;background:none!important;border:0!important;box-shadow:none!important;padding:0!important;min-height:0!important;cursor:pointer;text-decoration:underline}`;
  function tela(html) {
    let el = document.getElementById("cx");
    if (!el) {
      const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);
      el = document.createElement("div"); el.id = "cx"; document.body.appendChild(el);
    }
    el.innerHTML = `<div class="cx-c"><div style="font-size:26px">✦</div>${html}</div>`;
    return el;
  }
  const fecharTela = () => document.getElementById("cx")?.remove();
  const msg = (t, err) => { const m = document.querySelector("#cx .cx-m"); if (m) { m.textContent = t; m.className = "cx-m" + (err ? " err" : ""); } };

  function telaEntrar() {
    tela(`<h1>Central VitaPower</h1><p>Entre com o seu e-mail. Enviamos um link de acesso, sem senha.</p>
<form id="cxF"><label for="cxE">E-mail</label><input id="cxE" type="email" autocomplete="email" required placeholder="voce@vitapowernutrition.com.br">
<button id="cxB">Receber link de acesso</button></form>
<div id="cxCod" hidden><label for="cxC">Ou digite o código do e-mail</label><input id="cxC" inputmode="numeric" autocomplete="one-time-code" maxlength="8" placeholder="123456"><button id="cxCB" type="button">Entrar com o código</button></div>
<div class="cx-m"></div>`);
    const f = document.getElementById("cxF");
    f.addEventListener("submit", async (e) => {
      e.preventDefault();
      const em = document.getElementById("cxE").value.trim().toLowerCase();
      const b = document.getElementById("cxB"); b.disabled = true; msg("Enviando…");
      const { error } = await sb.auth.signInWithOtp({ email: em, options: { emailRedirectTo: location.origin + location.pathname } });
      b.disabled = false;
      if (error) { msg(error.status === 429 ? "Muitos pedidos seguidos. Espere um minuto e tente de novo." : "Não foi possível enviar o link: " + error.message, true); return; }
      msg("Pronto! Abra o e-mail que chegou para " + em + " e toque no link. Pode fechar esta aba depois.");
      b.textContent = "Reenviar link";
      document.getElementById("cxCod").hidden = false;
      document.getElementById("cxCB").onclick = async () => {
        const token = document.getElementById("cxC").value.trim();
        if (!token) return;
        const { error: e2 } = await sb.auth.verifyOtp({ email: em, token, type: "email" });
        if (e2) msg("Código inválido ou vencido. Peça um novo link.", true);
      };
    });
  }

  function telaSemAcesso() {
    tela(`<h1>Sem acesso</h1><p>A conta <b>${email.replace(/[<>&]/g, "")}</b> ainda não faz parte do time da Central. Peça para o Andrew liberar o seu e-mail.</p><button id="cxS">Entrar com outro e-mail</button>`);
    document.getElementById("cxS").onclick = () => sb.auth.signOut();
  }

  function telaNome(sugestao) {
    return new Promise((res) => {
      tela(`<h1>Bem-vindo(a)!</h1><p>Como o time deve te chamar?</p><form id="cxN"><label for="cxNo">Seu nome</label><input id="cxNo" required autocomplete="name" value="${sugestao.replace(/"/g, "")}"><button>Continuar</button></form><div class="cx-m"></div>`);
      document.getElementById("cxN").addEventListener("submit", (e) => { e.preventDefault(); res(document.getElementById("cxNo").value.trim()); });
    });
  }

  async function aoEntrar(session) {
    uid = session.user.id; email = (session.user.email || "").toLowerCase();
    const { data: p, error } = await sb.from("central_perfis").select("nome").eq("id", uid).maybeSingle();
    if (error) { tela(`<h1>Algo deu errado</h1><p>Não consegui falar com o servidor. Verifique a internet e recarregue a página.</p>`); return; }
    meuNome = p?.nome || "";
    if (!meuNome) {
      const base = email.split("@")[0].replace(/[._-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
      const nome = await telaNome(base);
      const { error: e2 } = await sb.from("central_perfis").upsert({ id: uid, nome, email });
      if (e2) { telaSemAcesso(); return; }
      meuNome = nome;
    }
    fecharTela();
    botaoSair();
    liberar();
  }

  function botaoSair() {
    const q = document.getElementById("quem");
    if (!q || document.querySelector(".cx-sair")) return;
    const b = document.createElement("button"); b.type = "button"; b.className = "cx-sair"; b.textContent = "Sair";
    b.onclick = async () => { await sb.auth.signOut(); location.reload(); };
    q.insertAdjacentElement("afterend", b);
  }

  let iniciado = false;
  sb.auth.onAuthStateChange((ev, session) => {
    if (ev === "SIGNED_OUT") { if (iniciado) location.reload(); else telaEntrar(); return; }
    if (session && !iniciado && (ev === "INITIAL_SESSION" || ev === "SIGNED_IN")) {
      iniciado = true;
      setTimeout(() => aoEntrar(session), 0);
    } else if (!session && ev === "INITIAL_SESSION") {
      const vai = () => telaEntrar();
      document.body ? vai() : document.addEventListener("DOMContentLoaded", vai);
    }
  });

  /* ---------- dados: coleções no formato que o app espera ---------- */
  const nomeColecao = (n) => (n.startsWith("data/users/") ? "pessoal:" + n.slice(11) : n);
  const ouvintes = new Map(); // colecao -> Set de {mapa, emitir}
  let canal = null, conectouAntes = false;

  function snap(mapa) {
    return { docs: [...mapa.entries()].map(([id, dados]) => ({ id, exists: true, data: () => dados })) };
  }
  async function carregar(colecao) {
    const mapa = new Map();
    for (let de = 0; ; de += 1000) {
      const { data, error } = await sb.from("central_docs").select("doc_id,dados").eq("colecao", colecao).range(de, de + 999);
      if (error) throw error;
      data.forEach((r) => mapa.set(r.doc_id, r.dados));
      if (data.length < 1000) break;
    }
    return mapa;
  }
  function aplicar(colecao, id, dados) {
    const s = ouvintes.get(colecao); if (!s) return;
    s.forEach((o) => { if (dados === null) o.mapa.delete(id); else o.mapa.set(id, dados); o.emitir(); });
  }
  function ligarCanal() {
    if (canal) return;
    canal = sb.channel("central-docs")
      .on("postgres_changes", { event: "*", schema: "public", table: "central_docs" }, (p) => {
        if (p.eventType === "DELETE") aplicar(p.old?.colecao, p.old?.doc_id, null);
        else aplicar(p.new.colecao, p.new.doc_id, p.new.dados);
      })
      .subscribe((st) => {
        if (st !== "SUBSCRIBED") return;
        if (conectouAntes) recarregarTudo(); // voltou depois de cair: busca o que mudou nesse meio-tempo
        conectouAntes = true;
      });
  }
  async function recarregarTudo() {
    for (const [colecao, s] of ouvintes) {
      try { const m = await carregar(colecao); s.forEach((o) => { o.mapa.clear(); m.forEach((v, k) => o.mapa.set(k, v)); o.emitir(); }); } catch (e) {}
    }
  }
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && ouvintes.size) recarregarTudo(); });

  function colecao(nome) {
    const c = nomeColecao(nome);
    if (!TIMES.includes(c) && c !== "pessoal:" + uid) throw new Error("coleção desconhecida: " + nome);
    return {
      doc(id) {
        return {
          async set(dados) {
            const { error } = await sb.from("central_docs").upsert({ colecao: c, doc_id: id, dados });
            if (error) throw error;
            aplicar(c, id, dados);
          },
          async delete() {
            const { error } = await sb.from("central_docs").delete().eq("colecao", c).eq("doc_id", id);
            if (error) throw error;
            aplicar(c, id, null);
          },
          async get() {
            const { data } = await sb.from("central_docs").select("dados").eq("colecao", c).eq("doc_id", id).maybeSingle();
            return { id, exists: !!data, data: () => data?.dados };
          },
          // a trava de edição de páginas fica sempre liberada aqui
          async acquire() { return { acquired: true }; },
        };
      },
      onSnapshot(cb, erro) {
        const o = { mapa: new Map(), emitir: () => cb(snap(o.mapa)) };
        if (!ouvintes.has(c)) ouvintes.set(c, new Set());
        ouvintes.get(c).add(o);
        ligarCanal();
        carregar(c).then((m) => { m.forEach((v, k) => o.mapa.set(k, v)); o.emitir(); }, (e) => erro && erro(e));
        return () => ouvintes.get(c)?.delete(o);
      },
    };
  }

  /* ---------- pessoas ---------- */
  let perfis = null;
  async function todosPerfis() {
    if (!perfis) {
      const { data } = await sb.from("central_perfis").select("id,nome").order("nome");
      perfis = (data || []).map((p) => ({ id: p.id, name: p.nome }));
    }
    return perfis;
  }

  /* ---------- assistente (função na Vercel) ---------- */
  async function assistente(messages, opts = {}) {
    const { data } = await sb.auth.getSession();
    const token = data.session?.access_token;
    if (!token) throw { code: "session_expired" };
    let r;
    try {
      r = await fetch("/api/assistente", {
        method: "POST", signal: opts.signal,
        headers: { "content-type": "application/json", authorization: "Bearer " + token },
        body: JSON.stringify({ messages }),
      });
    } catch (e) {
      if (e && e.name === "AbortError") throw { code: "cancelled" };
      throw { code: "network", message: "Sem conexão" };
    }
    const j = await r.json().catch(() => null);
    if (!r.ok || !j || j.error) throw { code: j?.error?.code || "erro", message: j?.error?.message || "Falha no assistente" };
    return j.resultado;
  }

  // o botão do assistente só aparece para quem está liberado e quando a chave do Claude está configurada
  async function assistenteAtivo() {
    try {
      const { data } = await sb.auth.getSession();
      const r = await fetch("/api/assistente", { headers: { authorization: "Bearer " + data.session?.access_token } });
      return r.ok && (await r.json()).ativo === true;
    } catch (e) { return false; }
  }

  /* ---------- histórico de versões e lixeira (tabela central_docs_historico, gravada pelo banco) ---------- */
  const nomeApp = (c) => (c.startsWith("pessoal:") ? "pessoal" : c);
  const nomeBanco = (c) => (c === "pessoal" ? "pessoal:" + uid : c);
  const historico = {
    async lixeira() {
      const { data, error } = await sb.from("central_lixeira").select("colecao,doc_id,dados,em,por").order("em", { ascending: false }).limit(200);
      if (error) throw error;
      return data.map((r) => ({ colecao: nomeApp(r.colecao), id: r.doc_id, dados: r.dados, em: r.em, por: r.por }));
    },
    async versoes(colecao, id) {
      const { data, error } = await sb.from("central_docs_historico").select("id,operacao,dados,em,por")
        .eq("colecao", nomeBanco(colecao)).eq("doc_id", id).order("id", { ascending: false }).limit(100);
      if (error) throw error;
      return data.map((r) => ({ n: r.id, operacao: r.operacao, dados: r.dados, em: r.em, por: r.por }));
    },
  };
  // enquanto a migração 003_historico.sql não estiver aplicada, o app simplesmente não mostra histórico e lixeira
  let temHistorico = null;
  async function historicoAtivo() {
    if (temHistorico === null) {
      const { error } = await sb.from("central_docs_historico").select("id").limit(1);
      temHistorico = !error;
    }
    return temHistorico;
  }

  /* ---------- a interface que o app usa ---------- */
  const servicos = {
    db: { collection: colecao },
    user: {
      id: async () => uid,
      me: async () => ({ id: uid, name: meuNome, email }),
      isOwner: async () => false,
      can: async () => true,
      search: async () => todosPerfis(),
      profiles: async (ids) => {
        const ps = await todosPerfis(), out = {};
        ids.forEach((id) => { const p = ps.find((x) => x.id === id); if (p) out[id] = { name: p.name }; });
        return out;
      },
    },
    sample: { json: assistente, limits: async () => ({ maxPromptBytes: 262144 }) },
    historico,
  };
  window.claude = {
    async use(nome) {
      if (!(nome in servicos)) return null;
      await pronto;
      if (nome === "sample" && !(await assistenteAtivo())) return null;
      if (nome === "historico" && !(await historicoAtivo())) return null;
      return servicos[nome];
    },
  };

  if ("serviceWorker" in navigator) addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
})();

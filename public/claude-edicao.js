/* Central VitaPower, versão aberta dentro do Claude (o link de artifact do Andrew).
   Lê e grava os mesmos dados do app da Vercel (tabela central_docs no Supabase) pelo conector do Supabase,
   e usa a IA da própria assinatura do Claude para o assistente. Entra no artifact por scripts/montar-claude.py. */
(function () {
  const PROJ = "tlbufqzembztbhcfdccg";
  const DONO = "5a9a7f8b-832e-49f0-b798-96981cfff56e"; // Andrew no Supabase Auth: dono dos itens pessoais desta versão
  const TIMES = ["tarefas", "projetos", "paginas", "config"];
  const URL_TIME = "https://central-vitapower.vercel.app";

  let mcp = null, perfis = null, busca = null, timer = null;
  const ouvintes = new Map();
  window.CENTRAL = { modo: "claude" };

  const lit = (s) => { s = String(s); let t; do { t = "$c" + Math.random().toString(36).slice(2, 9) + "$"; } while (s.includes(t)); return t + s + t; };
  async function sql(q) {
    const r = await mcp.callTool("Supabase", "execute_sql", { project_id: PROJ, query: q }, { cache: false });
    const pl = r && r.payload;
    if (Array.isArray(pl)) return pl;
    const t = typeof pl === "string" ? pl : (pl && typeof pl.result === "string" ? pl.result : ((r && r.content) || []).map((c) => c.text || "").join("\n"));
    const tx = String(t || ""), fim = tx.lastIndexOf("</untrusted-data-"), ini = fim < 0 ? -1 : tx.lastIndexOf("<untrusted-data-", fim), abre = ini < 0 ? -1 : tx.indexOf(">", ini);
    if (fim < 0 || ini < 0 || abre < 0 || abre > fim) throw { code: "resposta", message: tx.slice(0, 300) };
    return JSON.parse(tx.slice(abre + 1, fim).trim());
  }
  function aviso(e) {
    const c = e && e.code;
    if (c === "dono") return "Este link é a versão do Andrew, com o assistente. Para usar a Central, abra " + URL_TIME;
    if (c === "sem_mcp" || c === "server_not_connected") return "Para abrir a Central aqui, conecte o Supabase em Configurações → Conectores do Claude e recarregue a página. Ou use " + URL_TIME;
    if (c === "needs_reauth") return "A conexão com o Supabase expirou. Reconecte em Configurações → Conectores e recarregue a página.";
    if (c === "not_granted" || c === "denied") return "A página precisa da sua permissão para usar o Supabase. Libere no menu de Permissões e recarregue.";
    return "Não consegui falar com o Supabase agora. Recarregue a página em alguns segundos. Ou use " + URL_TIME;
  }

  /* ---------- coleções no formato que o app espera ---------- */
  const nomeColecao = (n) => (n.startsWith("data/users/") ? "pessoal:" + DONO : n);
  const assinatura = (m) => JSON.stringify([...m.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)));
  function emitir(o) { o.cb({ docs: [...o.mapa.entries()].map(([id, d]) => ({ id, exists: true, data: () => d })) }); }
  function local(c, id, d) {
    ouvintes.get(c)?.forEach((o) => { if (d === null) o.mapa.delete(id); else o.mapa.set(id, d); o.h = assinatura(o.mapa); emitir(o); });
  }
  function buscar() {
    if (busca) return busca;
    busca = (async () => {
      await null; // junta os onSnapshot registrados no mesmo instante numa consulta só
      const cols = [...ouvintes.keys()];
      if (!cols.length) return;
      try {
        const rows = await sql(`select colecao, doc_id, dados from public.central_docs where colecao in (${cols.map(lit).join(",")})`);
        const por = new Map(cols.map((c) => [c, new Map()]));
        rows.forEach((r) => por.get(r.colecao)?.set(r.doc_id, r.dados));
        por.forEach((m, c) => ouvintes.get(c).forEach((o) => {
          const h = assinatura(m);
          if (h === o.h) return;
          o.h = h; o.mapa = new Map(m); emitir(o);
        }));
      } catch (e) {
        ouvintes.forEach((s) => s.forEach((o) => { if (o.h === null && o.err) o.err(e); }));
      } finally { busca = null; }
    })();
    return busca;
  }
  function colecao(nome) {
    const c = nomeColecao(nome);
    return {
      doc(id) {
        return {
          async set(d) {
            await sql(`insert into public.central_docs (colecao, doc_id, dados) values (${lit(c)}, ${lit(id)}, ${lit(JSON.stringify(d))}::jsonb) on conflict (colecao, doc_id) do update set dados = excluded.dados`);
            local(c, id, d);
          },
          async delete() {
            await sql(`delete from public.central_docs where colecao = ${lit(c)} and doc_id = ${lit(id)}`);
            local(c, id, null);
          },
          async get() {
            const r = await sql(`select dados from public.central_docs where colecao = ${lit(c)} and doc_id = ${lit(id)}`);
            return { id, exists: !!r[0], data: () => r[0]?.dados };
          },
          async acquire() { return { acquired: true }; },
        };
      },
      onSnapshot(cb, err) {
        const o = { mapa: new Map(), cb, err, h: null };
        if (!ouvintes.has(c)) ouvintes.set(c, new Set());
        ouvintes.get(c).add(o);
        buscar();
        if (!timer) {
          // sem tempo real por aqui: confere mudanças do time a cada 30 s com a aba aberta
          timer = setInterval(() => { if (document.visibilityState === "visible") buscar(); }, 30000);
          document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") buscar(); });
        }
        return () => ouvintes.get(c)?.delete(o);
      },
    };
  }

  async function todosPerfis() {
    if (!perfis) {
      try { perfis = (await sql("select id::text as id, nome from public.central_perfis order by nome")).map((p) => ({ id: p.id, name: p.nome })); }
      catch (e) { perfis = []; }
    }
    return perfis;
  }

  let pronto = null;
  function iniciar() {
    if (pronto) return pronto;
    pronto = (async () => {
      const u = await window.claude?.use?.("user");
      if (u && !(await u.isOwner().catch(() => false))) throw { code: "dono" };
      mcp = await window.claude?.use?.("mcp");
      if (!mcp) throw { code: "sem_mcp" };
      await sql("select 1 as ok");
      return u;
    })();
    return pronto;
  }

  window.CENTRAL_USE = async function (nome) {
    if (nome === "db") {
      try { await iniciar(); } catch (e) { window.CENTRAL.aviso = aviso(e); return null; }
      return { collection: colecao };
    }
    if (nome === "user") {
      let u = null;
      try { u = await iniciar(); } catch (e) { return null; }
      return {
        id: async () => DONO,
        me: async () => ({ id: DONO, name: (await todosPerfis()).find((p) => p.id === DONO)?.name || (await u?.me?.())?.name || "" }),
        isOwner: async () => false,
        can: async () => true,
        search: async () => todosPerfis(),
        profiles: async (ids) => {
          const ps = await todosPerfis(), out = {};
          ids.forEach((id) => { const p = ps.find((x) => x.id === id); if (p) out[id] = { name: p.name }; });
          return out;
        },
      };
    }
    if (nome === "mcp") return null; // a cópia de segurança antiga não é mais necessária: os dados já estão no Supabase
    return window.claude?.use?.(nome);
  };
})();

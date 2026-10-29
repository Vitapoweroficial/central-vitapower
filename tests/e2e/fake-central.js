/* Substitui o central.js nos testes de interface: mesmo contrato (window.claude.use: db, user, historico),
   com os dados em sessionStorage para sobreviver a recarregar a página, e o histórico gravado como o trigger do banco faz. */
(function () {
  const UID = "aaaaaaaa-0000-0000-0000-000000000001";
  const CHAVE = "fake-central";
  const cfg = window.__FAKE__ || {};
  const est = JSON.parse(sessionStorage.getItem(CHAVE) || '{"docs":{},"hist":[],"seq":0}');
  const salvar = () => sessionStorage.setItem(CHAVE, JSON.stringify(est));
  window.__fakeEstado = () => JSON.parse(JSON.stringify(est));
  window.CENTRAL = { modo: "teste" };

  const nomeColecao = (n) => (n.startsWith("data/users/") ? "pessoal:" + n.slice(11) : n);
  const k = (c, id) => c + "\u0000" + id;
  const ouvintes = new Map();
  function registrar(c, id, op, dados) {
    est.hist.push({ n: ++est.seq, colecao: c, doc_id: id, operacao: op, dados, em: new Date(Date.now() + est.seq).toISOString(), por: UID });
  }
  function emitir(c) {
    const docs = Object.values(est.docs).filter((d) => d.colecao === c).map((d) => ({ id: d.doc_id, exists: true, data: () => JSON.parse(JSON.stringify(d.dados)) }));
    (ouvintes.get(c) || []).forEach((cb) => cb({ docs }));
  }
  function colecao(nome) {
    const c = nomeColecao(nome);
    return {
      doc(id) {
        return {
          async set(dados) {
            const ant = est.docs[k(c, id)];
            dados = JSON.parse(JSON.stringify(dados));
            if (!ant) registrar(c, id, "criar", dados);
            else if (JSON.stringify(ant.dados) !== JSON.stringify(dados)) registrar(c, id, "editar", dados);
            est.docs[k(c, id)] = { colecao: c, doc_id: id, dados };
            salvar(); emitir(c);
          },
          async delete() {
            const ant = est.docs[k(c, id)];
            if (ant) { registrar(c, id, "excluir", ant.dados); delete est.docs[k(c, id)]; }
            salvar(); emitir(c);
          },
          async get() { const d = est.docs[k(c, id)]; return { id, exists: !!d, data: () => d && d.dados }; },
          async acquire() { return { acquired: true }; },
        };
      },
      onSnapshot(cb) {
        if (!ouvintes.has(c)) ouvintes.set(c, new Set());
        ouvintes.get(c).add(cb);
        setTimeout(() => emitir(c), 0);
        return () => ouvintes.get(c).delete(cb);
      },
    };
  }
  const app = (c) => (c.startsWith("pessoal:") ? "pessoal" : c);
  const banco = (c) => (c === "pessoal" ? "pessoal:" + UID : c);
  const historico = {
    async lixeira() {
      const vivos = new Set(Object.values(est.docs).map((d) => d.doc_id)), visto = new Set();
      return est.hist.slice().reverse().filter((h) => h.operacao === "excluir" && !vivos.has(h.doc_id) && !visto.has(h.doc_id) && visto.add(h.doc_id))
        .map((h) => ({ colecao: app(h.colecao), id: h.doc_id, dados: h.dados, em: h.em, por: h.por }));
    },
    async versoes(c, id) {
      return est.hist.filter((h) => h.colecao === banco(c) && h.doc_id === id).reverse()
        .map((h) => ({ n: h.n, operacao: h.operacao, dados: h.dados, em: h.em, por: h.por }));
    },
  };
  const servicos = {
    db: { collection: colecao },
    user: {
      id: async () => UID, me: async () => ({ id: UID, name: "Pessoa de Teste" }), isOwner: async () => false, can: async () => true,
      search: async () => [{ id: UID, name: "Pessoa de Teste" }],
      profiles: async (ids) => Object.fromEntries(ids.filter((i) => i === UID).map((i) => [i, { name: "Pessoa de Teste" }])),
    },
  };
  if (cfg.historico !== false) servicos.historico = historico;
  window.claude = { use: async (n) => servicos[n] || null };
})();

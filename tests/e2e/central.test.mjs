// Testes de interface da Central: abrem o app de verdade (public/index.html) num Chromium sem tela,
// trocando só o acesso ao Supabase por um banco falso em memória (fake-central.js).
// Uso: node --test tests/e2e/   (precisa do Playwright com Chromium instalado)
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const raiz = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const fake = fs.readFileSync(path.join(raiz, "tests/e2e/fake-central.js"), "utf8");
const TIPOS = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".png": "image/png", ".webmanifest": "application/manifest+json" };

let srv, base, browser;
before(async () => {
  srv = http.createServer((req, res) => {
    const u = new URL(req.url, "http://x");
    const f = path.join(raiz, "public", u.pathname === "/" ? "index.html" : decodeURIComponent(u.pathname));
    if (!f.startsWith(path.join(raiz, "public")) || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { "content-type": TIPOS[path.extname(f)] || "application/octet-stream" });
    fs.createReadStream(f).pipe(res);
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${srv.address().port}/`;
  browser = await chromium.launch();
});
after(async () => { await browser?.close(); srv?.close(); });

async function abrir({ historico = true, largura = 1280, semente = null, ia = false, anexos = true } = {}) {
  const ctx = await browser.newContext({ viewport: { width: largura, height: 900 }, serviceWorkers: "block" });
  await ctx.addInitScript((h) => { window.__FAKE__ = { historico: h.historico, ia: h.ia, anexos: h.anexos }; localStorage.setItem("tarefas-vista", JSON.stringify("time")); localStorage.setItem("tarefas-modo", JSON.stringify("kanban")); }, { historico, ia, anexos });
  // semente: dados iniciais do banco simulado (só na primeira carga da aba)
  if (semente) await ctx.addInitScript((s) => { if (!sessionStorage.getItem("fake-central")) sessionStorage.setItem("fake-central", s); }, JSON.stringify(semente));
  await ctx.route("**/vendor/supabase-*.js", (r) => r.fulfill({ contentType: "text/javascript", body: "" }));
  await ctx.route("**/central.js", (r) => r.fulfill({ contentType: "text/javascript", body: fake }));
  const page = await ctx.newPage();
  const erros = [];
  page.on("pageerror", (e) => erros.push(e.message));
  await page.goto(base);
  await page.waitForFunction(() => typeof window.__fakeEstado === "function");
  return { page, ctx, erros };
}
const estado = (page) => page.evaluate(() => window.__fakeEstado());
const tarefa = (est, titulo) => Object.values(est.docs).find((d) => d.dados.titulo === titulo);
async function criarRapida(page, titulo) {
  await page.fill("#qTitulo", titulo);
  await page.press("#qTitulo", "Enter");
  await page.locator("#board .card", { hasText: titulo }).waitFor();
}

test("Cenário A/G: projeto e tarefa persistem depois de recarregar", async () => {
  const { page, ctx, erros } = await abrir();
  await page.click("#btnNovoProj");
  await page.fill("#pNome", "Lançamento teste");
  await page.click("#frmP button[type=submit]");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.colecao === "projetos"));
  await criarRapida(page, "Aprovar rótulo");
  await page.reload();
  await page.locator("#board .card", { hasText: "Aprovar rótulo" }).waitFor();
  const est = await estado(page);
  assert.equal(tarefa(est, "Aprovar rótulo").colecao, "tarefas");
  assert.ok(Object.values(est.docs).some((d) => d.colecao === "projetos" && d.dados.nome === "Lançamento teste"));
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Cenário B: arrastar no kanban grava a situação e a lista mostra o mesmo registro", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Cotar frascos");
  await page.locator("#board .card", { hasText: "Cotar frascos" }).dragTo(page.locator('#board section.col[data-col="fazendo"]'));
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.titulo === "Cotar frascos" && d.dados.status === "fazendo"));
  assert.equal(await page.locator('#board section.col[data-col="fazendo"] .card', { hasText: "Cotar frascos" }).count(), 1);
  await page.click('#modoVis [data-m="lista"]');
  await page.locator("#lista", { hasText: "Cotar frascos" }).waitFor();
  assert.match(await page.locator("#lista").innerText(), /Fazendo/);
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Lixeira: tarefa excluída aparece na lixeira e volta igual ao restaurar", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Revisar laudo");
  const antes = tarefa(await estado(page), "Revisar laudo");
  await page.locator("#board .card", { hasText: "Revisar laudo" }).click();
  await page.click("#tDel");
  assert.match(await page.locator("#tConfTx").innerText(), /Lixeira/);
  await page.click("#tConfS");
  await page.locator("#board .card", { hasText: "Revisar laudo" }).waitFor({ state: "detached" });
  assert.equal(tarefa(await estado(page), "Revisar laudo"), undefined);

  await page.click("#navLix");
  const item = page.locator("#lixeira .lxi", { hasText: "Revisar laudo" });
  await item.waitFor();
  await item.locator("button", { hasText: "Restaurar" }).click();
  await item.waitFor({ state: "detached" });
  const depois = tarefa(await estado(page), "Revisar laudo");
  assert.deepEqual(depois, antes);
  await page.click('#navAt [data-go="time"]');
  await page.locator("#board .card", { hasText: "Revisar laudo" }).waitFor();
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Versões: lista o que mudou e restaura uma versão anterior", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Título antigo");
  await page.locator("#board .card", { hasText: "Título antigo" }).click();
  await page.fill("#tTitulo", "Título novo");
  await page.click("#tSalvar");
  await page.locator("#board .card", { hasText: "Título novo" }).waitFor();

  await page.locator("#board .card", { hasText: "Título novo" }).click();
  await page.click("#tVer");
  await page.locator("#vLista .vi").nth(1).waitFor();
  assert.equal(await page.locator("#vLista .vi").count(), 2);
  assert.match(await page.locator("#vLista .vi").first().innerText(), /mudou: título/);
  assert.match(await page.locator("#vLista .vi").first().innerText(), /atual/);
  await page.locator("#vLista .vi").nth(1).locator("button", { hasText: "Restaurar esta" }).click();
  await page.click('#cfDlg [data-r="1"]');
  await page.locator("#board .card", { hasText: "Título antigo" }).waitFor();
  const est = await estado(page);
  assert.ok(tarefa(est, "Título antigo"));
  assert.equal(tarefa(est, "Título novo"), undefined);
  assert.equal(est.hist.filter((h) => h.operacao !== "excluir").length, 3, "restauração vira mais uma versão");
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Sem a migração do histórico, o app funciona e não mostra lixeira nem versões", async () => {
  const { page, ctx, erros } = await abrir({ historico: false });
  await criarRapida(page, "Sem histórico");
  assert.equal(await page.locator("#navLix").isHidden(), true);
  await page.locator("#board .card", { hasText: "Sem histórico" }).click();
  assert.equal(await page.locator("#tVer").isHidden(), true);
  await page.click("#tDel");
  assert.match(await page.locator("#tConfTx").innerText(), /de vez/);
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Celular (iPhone): lixeira abre pelo menu e restaura", async () => {
  const { page, ctx, erros } = await abrir({ largura: 390 });
  await criarRapida(page, "Tarefa no celular");
  await page.locator("#board .card", { hasText: "Tarefa no celular" }).click();
  await page.click("#tDel");
  await page.click("#tConfS");
  await page.click("#btnMenu");
  await page.click("#navLix");
  const item = page.locator("#lixeira .lxi", { hasText: "Tarefa no celular" });
  await item.waitFor();
  const larg = await page.evaluate(() => document.documentElement.scrollWidth);
  assert.ok(larg <= 390, "sem rolagem horizontal: " + larg);
  await item.locator("button", { hasText: "Restaurar" }).click();
  await item.waitFor({ state: "detached" });
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Edição simultânea: salvar por cima da mudança de outra pessoa pergunta antes", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Pedido de frascos");
  const id = tarefa(await estado(page), "Pedido de frascos").doc_id;

  // abro a tarefa, a colega muda a prioridade enquanto eu edito, e eu salvo: o app pergunta
  await page.locator("#board .card", { hasText: "Pedido de frascos" }).click();
  await page.fill("#tDesc", "minha anotação");
  await page.evaluate((id) => window.__fakeOutraPessoa("tarefas", id, { prioridade: "alta" }), id);
  await page.click("#tSalvar");
  await page.locator("#cfDlg[open]").waitFor();
  assert.match(await page.locator("#cfDlg .cfm").innerText(), /enquanto você editava/);
  // cancelar mantém a versão da colega
  await page.click('#cfDlg [data-r="0"]');
  await page.locator("#dlgT").waitFor({ state: "hidden" });
  let d = tarefa(await estado(page), "Pedido de frascos").dados;
  assert.equal(d.prioridade, "alta");
  assert.equal(d.descricao ?? "", "");

  // de novo, mas agora escolho salvar a minha por cima
  await page.locator("#board .card", { hasText: "Pedido de frascos" }).click();
  await page.fill("#tDesc", "minha anotação");
  await page.evaluate((id) => window.__fakeOutraPessoa("tarefas", id, { prioridade: "baixa" }), id);
  await page.click("#tSalvar");
  await page.click('#cfDlg [data-r="1"]');
  await page.locator("#dlgT").waitFor({ state: "hidden" });
  d = tarefa(await estado(page), "Pedido de frascos").dados;
  assert.equal(d.descricao, "minha anotação");

  // mudança feita a partir do quadro já atualizado não pergunta nada
  await page.evaluate((id) => window.__fakeOutraPessoa("tarefas", id, { prioridade: "media" }), id);
  await page.locator("#board .card", { hasText: "Pedido de frascos" }).dragTo(page.locator('#board section.col[data-col="fazendo"]'));
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.titulo === "Pedido de frascos" && d.dados.status === "fazendo"));
  assert.equal(await page.locator("#cfDlg[open]").count(), 0);
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Permissões: dono restringe o projeto e quem é só leitura não altera as tarefas", async () => {
  const { page, ctx, erros } = await abrir();
  await page.click("#btnNovoProj");
  await page.fill("#pNome", "Fórmula sigilosa");
  await page.click("#frmP button[type=submit]");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.colecao === "projetos"));
  const pid = Object.values((await estado(page)).docs).find((d) => d.colecao === "projetos").doc_id;
  await page.click('#navAt [data-go="projetos"]');
  await page.locator(".pcard", { hasText: "Fórmula sigilosa" }).click();

  // dono abre o projeto e restringe o acesso
  await page.locator("#pHead [data-ph=editar]").click();
  await page.locator("#pAcs").waitFor();
  await page.selectOption("#pAcesso", "restrito");
  assert.match(await page.locator("#pMembros").innerText(), /\(você\)/);
  assert.equal(await page.locator(`#pMembros select[data-m]`).first().inputValue(), "dono");
  await page.click("#frmP button[type=submit]");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.colecao === "projetos" && d.dados.acesso === "restrito"));
  await page.locator("#pHead", { hasText: "Restrito" }).waitFor();
  await criarRapida(page, "Teste de estabilidade");

  // agora a pessoa é só leitora: vê, mas não salva nem arrasta
  await page.evaluate((id) => window.__fakeOutraPessoa("projetos", id, { _papel: "leitor" }), pid);
  await page.locator("#pHead", { hasText: "Só leitura" }).waitFor();
  await page.locator("#board .card", { hasText: "Teste de estabilidade" }).click();
  assert.equal(await page.locator("#tSalvar").isHidden(), true);
  assert.equal(await page.locator("#tDel").isHidden(), true);
  await page.click("#tCancel");
  await page.locator("#board .card", { hasText: "Teste de estabilidade" }).dragTo(page.locator('#board section.col[data-col="fazendo"]'));
  await page.locator(".toast.on", { hasText: "só pode ver" }).waitFor();
  assert.equal(tarefa(await estado(page), "Teste de estabilidade").dados.status, "afazer");
  await page.locator("#pHead [data-ph=editar]", { hasText: "Ver projeto" }).click();
  assert.equal(await page.locator("#pDel").isHidden(), true);
  assert.equal(await page.locator("#pAcesso").isDisabled(), true);
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Central de Comando: conta o que pede ação e abre o registro com um clique", async () => {
  const { page, ctx, erros } = await abrir();
  const ontem = new Date(Date.now() - 86400000 * 2).toISOString().slice(0, 10);
  await page.fill("#qTitulo", "Laudo vencido");
  await page.fill("#qPrazo", ontem);
  await page.press("#qTitulo", "Enter");
  await page.locator("#board .card", { hasText: "Laudo vencido" }).waitFor();
  await criarRapida(page, "Sem dono definido");
  await page.click('#navAt [data-go="comando"]');
  await page.locator("#comando [data-cmd=late] .kv", { hasText: "1" }).waitFor();
  assert.match(await page.locator("#comando .hjsec").innerText(), /Laudo vencido/);
  assert.match(await page.locator("#comando .hjsec").innerText(), /Regra:/);
  await page.click("#comando [data-cmd=semresp]");
  await page.locator("#comando .hjsec", { hasText: "Sem dono definido" }).waitFor();
  await page.locator("#comando .hjsec .tt", { hasText: "Sem dono definido" }).click();
  await page.locator("#dlgT[open]").waitFor();
  assert.equal(await page.inputValue("#tTitulo"), "Sem dono definido");
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Busca global: acha tarefa por comentário e projeto pelo nome, e abre com Enter", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Comprar tampas");
  await page.locator("#board .card", { hasText: "Comprar tampas" }).click();
  await page.fill("#tComTx", "fornecedor Henriplast mandou orçamento");
  await page.click("#tComAdd");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => (d.dados.comentarios || []).length));
  await page.click("#tCancel");
  await page.keyboard.press("Control+k");
  await page.locator("#dlgBusca[open]").waitFor();
  await page.fill("#gbQ", "henriplást");
  await page.locator("#gbRes .gbi", { hasText: "Comprar tampas" }).waitFor();
  assert.match(await page.locator("#gbRes").innerText(), /Comentário/);
  await page.keyboard.press("Enter");
  await page.locator("#dlgT[open]").waitFor();
  assert.equal(await page.inputValue("#tTitulo"), "Comprar tampas");
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Etapas do fluxo: kanban com colunas próprias e a situação acompanha a etapa", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Whey morango");
  await page.click("#btnEtapas");
  await page.click('[data-emod="pd"]');
  await page.click("#frmE button[type=submit]");
  await page.locator('#board .col-h h2', { hasText: "Formulação" }).waitFor();
  assert.equal(await page.locator("#agrupar").inputValue(), "etapa");
  await page.locator("#board .card", { hasText: "Whey morango" }).waitFor();
  const col = page.locator("#board section.col", { has: page.locator(".col-h h2", { hasText: "Aprovação do cliente" }) });
  await page.locator("#board .card", { hasText: "Whey morango" }).dragTo(col);
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.titulo === "Whey morango" && d.dados.status === "aguardando" && d.dados.etapa));
  await col.locator(".card", { hasText: "Whey morango" }).waitFor();
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Documentos: trecho vira tarefa ligada, decisão registrada, aprovação trava a versão", async () => {
  const { page, ctx, erros } = await abrir();
  await page.click("#addTime");
  await page.locator("#vPagina:not([hidden])").waitFor();
  await page.waitForFunction(() => document.activeElement?.id === "pgTitulo");
  await page.fill("#pgTitulo", "POP Envase");
  await page.click("#ed");
  await page.keyboard.type("Calibrar a balança antes do turno");
  // seleciona o texto e transforma em tarefa
  await page.evaluate(() => { const r = document.createRange(); r.selectNodeContents(document.querySelector("#ed")); getSelection().removeAllRanges(); getSelection().addRange(r); });
  await page.click('#tb [data-cmd="tarefa"]');
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.titulo === "Calibrar a balança antes do turno" && d.dados.origemPagina));
  await page.locator('#ed a[href^="#tarefa-"]').waitFor();
  // decisão
  await page.evaluate(() => { const ed = document.querySelector("#ed"); ed.focus(); const r = document.createRange(); r.selectNodeContents(ed); r.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(r); });
  await page.click('#tb [data-cmd="decisao"]');
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.tipo === "pagina" && (d.dados.conteudo || "").includes("decisao")), null, { timeout: 8000 });
  // o link no texto abre a tarefa, e a tarefa mostra de onde veio
  await page.locator('#ed a[href^="#tarefa-"]').click();
  await page.locator("#dlgT[open]").waitFor();
  assert.match(await page.locator("#tOrigem").innerText(), /POP Envase/);
  await page.click("#tCancel");
  // pede aprovação à Bia
  await page.click("#pgEstado");
  await page.click('.pop.menu [data-k="pedir"]');
  await page.click('.pop.menu button:has-text("Bia Qualidade")');
  await page.locator("#pgAprov", { hasText: "Em revisão" }).waitFor();
  // Bia aprova (simulado): a página fica só para leitura
  const pg = Object.values((await estado(page)).docs).find((d) => d.dados.tipo === "pagina");
  await page.evaluate(({ id, ap }) => window.__fakeOutraPessoa("paginas", id, { estado: "aprovado", aprovacoes: ap.map((a) => ({ ...a, status: "aprovado", em: new Date().toISOString() })) }), { id: pg.doc_id, ap: pg.dados.aprovacoes });
  await page.locator("#pgAprov", { hasText: "Aprovado por Bia Qualidade" }).waitFor();
  assert.equal(await page.getAttribute("#ed", "contenteditable"), "false");
  // Central de Comando lista a decisão
  await page.click('#navAt [data-go="comando"]');
  await page.click("#comando [data-cmd=decis]");
  await page.locator("#comando .hjsec", { hasText: "Decisão" }).waitFor();
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Notificações e menções: @ no comentário e na página, aviso abre a tarefa", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Revisar rótulo do whey");
  await page.click("#board .card >> text=Revisar rótulo do whey");
  await page.locator("#dlgT[open]").waitFor();
  // menção no comentário: digita @Bi, escolhe na lista e envia
  await page.click("#tComTx");
  await page.keyboard.type("@Bi");
  await page.locator(".pop [data-mc]", { hasText: "Bia Qualidade" }).waitFor();
  await page.keyboard.press("Enter");
  await page.keyboard.type("confere a tabela?");
  assert.equal(await page.inputValue("#tComTx"), "@Bia Qualidade confere a tabela?");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => (d.dados.comentarios || []).some((c) => (c.mencoes || []).includes("bbbbbbbb-0000-0000-0000-000000000002"))));
  await page.locator("#tComs .mencao", { hasText: "@Bia Qualidade" }).waitFor();
  const id = tarefa(await estado(page), "Revisar rótulo do whey").doc_id;
  await page.keyboard.press("Escape");
  await page.locator("#dlgT").waitFor({ state: "hidden" });

  // chega um aviso: o sino mostra 1, a lista abre a tarefa e o aviso fica lido
  await page.evaluate((doc) => window.__fakeAviso({ tipo: "comentario", colecao: "tarefas", doc_id: doc, titulo: "Revisar rótulo do whey", trecho: "pode aprovar" }), id);
  await page.waitForFunction(() => document.querySelector("#nAvisos").textContent === "1");
  await page.click("#navAvisos");
  await page.locator("#avisos .avi.nova", { hasText: "Bia Qualidade" }).waitFor();
  await page.click("#avisos .avi");
  await page.locator("#dlgT[open]").waitFor();
  assert.equal(await page.inputValue("#tTitulo"), "Revisar rótulo do whey");
  await page.waitForFunction(() => document.querySelector("#nAvisos").textContent === "");
  await page.keyboard.press("Escape");

  // lembrete diário do banco (sem autor): frase própria
  await page.evaluate((doc) => window.__fakeAviso({ tipo: "prazo", por: null, colecao: "tarefas", doc_id: doc, titulo: "Revisar rótulo do whey" }), id);
  await page.locator("#avisos .avi.nova", { hasText: "A tarefa Revisar rótulo do whey vence hoje" }).waitFor();

  // menção na página vira um marcador com o id da pessoa
  await page.click("#addTime");
  await page.locator("#vPagina:not([hidden])").waitFor();
  await page.waitForFunction(() => document.activeElement?.id === "pgTitulo");
  await page.fill("#pgTitulo", "Reunião de rótulos");
  await page.click("#ed");
  await page.keyboard.type("Falar com @Bi");
  await page.locator(".pop [data-mc]", { hasText: "Bia Qualidade" }).waitFor();
  await page.keyboard.press("Enter");
  await page.keyboard.type("amanhã");
  await page.keyboard.press("Control+s");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.tipo === "pagina" && /data-mencao="bbbbbbbb-0000-0000-0000-000000000002"/.test(d.dados.conteudo || "")));
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Gantt e carga: setas de dependência, marco, arrastar barra e carga por pessoa", async () => {
  // um projeto com marco e tarefas do time com datas (duas dependentes, uma em conflito)
  const iso = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const UID = "aaaaaaaa-0000-0000-0000-000000000001";
  const doc = (colecao, doc_id, dados) => [colecao + "\u0000" + doc_id, { colecao, doc_id, dados: { _versao: 1, ...dados }, por: UID }];
  const docs = Object.fromEntries([
    doc("projetos", "pj", { nome: "Linha Kids", cor: "p2", status: "ativo", inicio: iso(-3), prazo: iso(30), membros: [{ id: UID, papel: "dono" }], _papel: "dono", entregas: [{ id: "m1", t: "Rótulo aprovado", ok: false, data: iso(10) }] }),
    doc("tarefas", "a", { tipo: "tarefa", titulo: "Fórmula", status: "fazendo", projetoId: "pj", inicio: iso(0), prazo: iso(4), respId: UID, ordem: 1 }),
    doc("tarefas", "b", { tipo: "tarefa", titulo: "Rótulo", status: "afazer", projetoId: "pj", inicio: iso(6), prazo: iso(9), respId: UID, dependeDe: ["a"], ordem: 2 }),
    doc("tarefas", "c", { tipo: "tarefa", titulo: "Teste de estabilidade", status: "afazer", projetoId: "pj", inicio: iso(2), prazo: iso(5), respId: UID, dependeDe: ["a"], ordem: 3 }),
    doc("tarefas", "d", { tipo: "tarefa", titulo: "Laudo", status: "afazer", inicio: iso(0), prazo: iso(3), respId: UID, ordem: 4 }),
  ]);
  const { page, ctx, erros } = await abrir({ semente: { docs, hist: [], seq: 0 } });
  await page.locator("#board .card", { hasText: "Laudo" }).waitFor();
  await page.click('#modoVis [data-m="linha"]');
  await page.locator("#linha .tldep").waitFor();
  assert.equal(await page.locator("#linha .tldep > path").count(), 2, "duas setas");
  assert.equal(await page.locator("#linha .tldep > path.conf").count(), 1, "uma em conflito");
  assert.equal(await page.locator("#linha .tlm").count(), 1, "o marco aparece");

  // arrastar a barra do Laudo 2 dias para a frente muda início e prazo
  const antes = tarefa(await estado(page), "Laudo").dados;
  const bar = page.locator('#linha .tlb[data-id="d"]');
  const r = await bar.boundingBox();
  await page.mouse.move(r.x + r.width / 2, r.y + r.height / 2);
  await page.mouse.down();
  await page.mouse.move(r.x + r.width / 2 + 22, r.y + r.height / 2, { steps: 3 });
  await page.mouse.move(r.x + r.width / 2 + 44, r.y + r.height / 2, { steps: 3 });
  await page.mouse.up();
  await page.waitForFunction((p) => Object.values(window.__fakeEstado().docs).some((d) => d.doc_id === "d" && d.dados.prazo !== p), antes.prazo);
  const depois = tarefa(await estado(page), "Laudo").dados;
  const mais2 = (iso) => { const d = new Date(iso + "T12:00:00"); d.setDate(d.getDate() + 2); return d.toISOString().slice(0, 10); };
  assert.equal(depois.inicio, mais2(antes.inicio));
  assert.equal(depois.prazo, mais2(antes.prazo));
  assert.equal(await page.locator("#dlgT[open]").count(), 0, "arrastar não abre a tarefa");

  // carga: com limite 2, esta semana fica acima do limite; clicar no número lista as tarefas
  await page.click('#modoVis [data-m="carga"]');
  await page.locator("#carga .cg").waitFor();
  await page.fill("#cgLim", "2");
  await page.dispatchEvent("#cgLim", "change");
  await page.locator("#carga .cel.over").first().waitFor();
  await page.click("#carga .cel.over >> nth=0");
  await page.locator(".pop.menu button", { hasText: "Fórmula" }).waitFor();
  await page.click(".pop.menu button >> text=Fórmula");
  await page.locator("#dlgT[open]").waitFor();
  assert.equal(await page.inputValue("#tTitulo"), "Fórmula");
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Métricas: período, tendência, desempenho por pessoa e projeto, planilha", async () => {
  const iso = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const UID = "aaaaaaaa-0000-0000-0000-000000000001";
  const doc = (colecao, doc_id, dados) => [colecao + "\u0000" + doc_id, { colecao, doc_id, dados: { _versao: 1, ...dados }, por: UID }];
  const docs = Object.fromEntries([
    doc("projetos", "pj", { nome: "Linha Kids", cor: "p2", status: "ativo", membros: [{ id: UID, papel: "dono" }], _papel: "dono" }),
    // 60 dias atrás: fora dos 30 dias, dentro dos 90
    doc("tarefas", "v", { tipo: "tarefa", titulo: "Antiga", status: "feito", respId: UID, criadoEm: iso(-64) + "T10:00:00Z", concluidoEm: iso(-60) + "T10:00:00Z", prazo: iso(-61) }),
    doc("tarefas", "n1", { tipo: "tarefa", titulo: "No prazo", status: "feito", projetoId: "pj", respId: UID, criadoEm: iso(-6) + "T10:00:00Z", concluidoEm: iso(-2) + "T10:00:00Z", prazo: iso(-1) }),
    doc("tarefas", "n2", { tipo: "tarefa", titulo: "Atrasou", status: "feito", projetoId: "pj", respId: UID, criadoEm: iso(-10) + "T10:00:00Z", concluidoEm: iso(-4) + "T10:00:00Z", prazo: iso(-8) }),
    doc("tarefas", "ab", { tipo: "tarefa", titulo: "Aberta", status: "afazer", respId: UID, prazo: iso(-1) }),
  ]);
  const { page, ctx, erros } = await abrir({ semente: { docs, hist: [], seq: 0 } });
  await page.click('[data-go="painel"]');
  await page.locator("#painel .kpi", { hasText: "Concluídas em 30 dias" }).waitFor();
  assert.match(await page.locator("#painel .kpi", { hasText: "Entregues no prazo" }).innerText(), /50%/);
  const pessoa = page.locator("#painel .panel", { hasText: "Desempenho por pessoa" });
  assert.match(await pessoa.locator("tbody tr").first().innerText(), /Você\s+2\s+50%\s+5 d\s+1\s+1/);
  assert.equal(await page.locator("#painel .panel", { hasText: "Desempenho por projeto" }).locator("tr[data-p]").count(), 1);
  assert.equal(await page.locator("#painel .panel", { hasText: "Entregues no prazo, por semana" }).locator("circle.pt").count() > 0, true);
  // 90 dias inclui a antiga
  await page.click('#painel [data-per="90"]');
  await page.locator("#painel .kpi", { hasText: "Concluídas em 90 dias" }).waitFor();
  assert.match(await page.locator("#painel .kpi", { hasText: "Concluídas em 90 dias" }).innerText(), /\n3\n/);
  // planilha
  const [dl] = await Promise.all([page.waitForEvent("download"), page.click("#pCsv")]);
  const txt = fs.readFileSync(await dl.path(), "utf8");
  assert.match(txt, /Tarefa;Projeto;Responsável/);
  assert.match(txt, /Atrasou;Linha Kids;.*;não;6;/);
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Assistente gestor: consulta a linha do tempo e a carga, pergunta, e propõe cronograma com responsável, dependência, marco e comentário", async () => {
  const UID = "aaaaaaaa-0000-0000-0000-000000000001", BIA = "bbbbbbbb-0000-0000-0000-000000000002";
  const doc = (colecao, doc_id, dados) => [colecao + "\u0000" + doc_id, { colecao, doc_id, dados: { _versao: 1, ...dados }, por: UID }];
  const docs = Object.fromEntries([
    doc("projetos", "pj", { nome: "Linha Kids", cor: "p2", status: "ativo", membros: [{ id: UID, papel: "dono" }], _papel: "dono", entregas: [{ id: "m1", t: "Rótulo aprovado", ok: false }] }),
    doc("tarefas", "a", { tipo: "tarefa", titulo: "Fórmula", status: "afazer", projetoId: "pj", ordem: 1 }),
    doc("tarefas", "b", { tipo: "tarefa", titulo: "Rótulo", status: "afazer", projetoId: "pj", ordem: 2 }),
    doc("tarefas", "v", { tipo: "tarefa", titulo: "Rótulo do whey", status: "feito", respId: BIA, concluidoEm: "2026-09-10T10:00:00Z", prazo: "2026-09-12", ordem: 3 }),
  ]);
  const { page, ctx, erros } = await abrir({ semente: { docs, hist: [], seq: 0 }, ia: true });
  await page.evaluate(([BIA]) => {
    let rodada = 0;
    window.__fakeIA = async (turnos, usar) => {
      rodada++;
      const pedido = turnos[turnos.length - 1].content;
      if (rodada === 1) {
        if (!/gestor do projeto “Linha Kids”/.test(pedido)) throw new Error("pedido inesperado: " + pedido);
        await usar("ver_projeto", { id: "pj" });
        await usar("carga_equipe", { semanas: 4 });
        await usar("historico_pessoa", { id: BIA });
        await usar("buscar", { texto: "rótulo" });
        return { resposta: "Antes de montar: 1. Qual a data de entrega do rótulo aprovado?", acoes: [] };
      }
      return { resposta: "Cronograma montado.", acoes: [
        { tipo: "alterar_projeto", id: "pj", mudancas: { prazo: "2030-03-29" }, marcos: [{ texto: "Rótulo aprovado", data: "2030-03-22" }] },
        { tipo: "alterar_tarefa", id: "a", mudancas: { inicio: "2030-03-04", prazo: "2030-03-08", prioridade: "alta", responsavel: BIA } },
        { tipo: "alterar_tarefa", id: "b", mudancas: { inicio: "2030-03-11", prazo: "2030-03-15", depende_de: ["a"] } },
        { tipo: "comentar", tarefa: "a", texto: "@Bia Qualidade você fica com a fórmula", mencoes: [BIA] },
        { tipo: "mover_datas", ids: ["b"], dias: 3 },
      ] };
    };
  }, [BIA]);
  await page.evaluate(() => ir("projeto", { proj: "pj" }));
  await page.click("#btnIA");
  await page.click("#iaSug button >> text=Organizar");
  await page.locator("#iaMsgs .msg.bot", { hasText: "data de entrega do rótulo" }).waitFor();
  const ch = await page.evaluate(() => window.__fakeIAChamadas);
  assert.deepEqual(ch.map((c) => c.nome), ["ver_projeto", "carga_equipe", "historico_pessoa", "buscar"]);
  assert.equal(ch[0].r.tarefas.length, 2);
  assert.equal(ch[0].r.marcos[0].texto, "Rótulo aprovado");
  assert.equal(ch[2].r.concluidas, 1);
  assert.ok(ch[3].r.some((x) => x.id === "v"), "busca devolve o id");

  await page.fill("#iaTexto", "Rótulo aprovado até 22/03/2030, projeto até 29/03.");
  await page.press("#iaTexto", "Enter");
  const plano = page.locator("#iaMsgs .plano").last();
  await plano.waitFor();
  assert.equal(await plano.locator("label").count(), 5);
  await plano.locator('[data-pl="ok"]').click();
  await plano.locator(".lock", { hasText: "5 mudanças aplicadas" }).waitFor();
  const est = await estado(page), d = (id) => Object.values(est.docs).find((x) => x.doc_id === id).dados;
  assert.equal(d("pj").prazo, "2030-03-29");
  assert.equal(d("pj").entregas[0].data, "2030-03-22");
  assert.equal(d("a").respId, BIA);
  assert.equal(d("a").prioridade, "alta");
  assert.deepEqual(d("b").dependeDe, ["a"]);
  assert.equal(d("b").inicio, "2030-03-14");
  assert.equal(d("b").prazo, "2030-03-18");
  assert.deepEqual(d("a").comentarios[0].mencoes, [BIA]);
  assert.deepEqual(erros, []);
  await ctx.close();
});

test("Anexos: PDF na tarefa e foto na página, abrem com um clique; sem Storage, só a lista", async () => {
  const { page, ctx, erros } = await abrir();
  await criarRapida(page, "Cotação de frascos");
  await page.locator("#board .card", { hasText: "Cotação de frascos" }).click();
  await page.locator("#dlgT[open]").waitFor();
  await page.locator("#tAnxBtn:visible").waitFor();
  await page.setInputFiles("#tAnxIn", { name: "cotação frascos.pdf", mimeType: "application/pdf", buffer: Buffer.from("preço 1,20") });
  await page.locator('#tLinks .anxa', { hasText: "cotação frascos.pdf" }).waitFor();
  await page.click("#tSalvar");
  await page.locator("#dlgT[open]").waitFor({ state: "detached" }).catch(() => {});
  let t = tarefa(await estado(page), "Cotação de frascos");
  assert.equal(t.dados.anexos.length, 1);
  assert.equal(t.dados.anexos[0].nome, "cotação frascos.pdf");
  assert.equal(t.dados.anexos[0].tipo, "application/pdf");
  assert.match(t.dados.anexos[0].caminho, new RegExp(`^tarefas/${t.doc_id}/`));
  // abre o arquivo em outra aba
  await page.locator("#board .card", { hasText: "Cotação de frascos" }).click();
  await page.locator("#dlgT[open]").waitFor();
  const [aba] = await Promise.all([ctx.waitForEvent("page"), page.click('#tLinks .anxa')]);
  await aba.waitForURL(/^blob:/);
  assert.match(await aba.locator("body").innerText(), /preço 1,20/);
  await aba.close();
  // tirar da lista não apaga o arquivo
  await page.click('#tLinks [data-tx="0"]');
  await page.click("#tSalvar");
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.titulo === "Cotação de frascos" && d.dados.anexos.length === 0));
  assert.equal(Object.keys(await page.evaluate(() => window.__fakeArquivos)).length, 1);
  // página: anexa e grava na hora
  await page.click("#addTime");
  await page.locator("#vPagina:not([hidden])").waitFor();
  await page.fill("#pgTitulo", "Laudos");
  await page.locator("#pgAnxBtn").waitFor();
  await page.setInputFiles("#pgAnxIn", [{ name: "laudo.jpg", mimeType: "image/jpeg", buffer: Buffer.from("foto") }, { name: "laudo2.pdf", mimeType: "application/pdf", buffer: Buffer.from("x") }]);
  await page.locator("#pgAnx h3", { hasText: "Anexos (2)" }).waitFor();
  await page.waitForFunction(() => Object.values(window.__fakeEstado().docs).some((d) => d.dados.tipo === "pagina" && d.dados.titulo === "Laudos" && (d.dados.anexos || []).length === 2));
  assert.match(await page.locator("#pgAnx").innerText(), /🖼️ laudo\.jpg/);
  assert.deepEqual(erros, []);
  await ctx.close();
  // versão sem Storage (como a do Claude): mostra os anexos, mas não oferece enviar
  const b = await abrir({ anexos: false });
  await criarRapida(b.page, "Sem storage");
  await b.page.locator("#board .card", { hasText: "Sem storage" }).click();
  await b.page.locator("#dlgT[open]").waitFor();
  assert.equal(await b.page.locator("#tAnxBtn").isVisible(), false);
  assert.deepEqual(b.erros, []);
  await b.ctx.close();
});

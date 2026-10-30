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

async function abrir({ historico = true, largura = 1280 } = {}) {
  const ctx = await browser.newContext({ viewport: { width: largura, height: 900 }, serviceWorkers: "block" });
  await ctx.addInitScript((h) => { window.__FAKE__ = { historico: h }; localStorage.setItem("tarefas-vista", JSON.stringify("time")); localStorage.setItem("tarefas-modo", JSON.stringify("kanban")); }, historico);
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

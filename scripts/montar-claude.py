"""Monta a versão do Claude (artifact do Andrew) a partir do mesmo public/index.html da Vercel.

Troca o supabase-js e o central.js pelo claude-edicao.js, que fala com o Supabase pelo conector do Claude.
Uso: python3 scripts/montar-claude.py [saida.html]   (padrão: dist/claude.html)
"""
import pathlib
import sys

raiz = pathlib.Path(__file__).resolve().parent.parent
pub = raiz / "public"
html = (pub / "index.html").read_text(encoding="utf8")
edicao = (pub / "claude-edicao.js").read_text(encoding="utf8")

tira = [
    '<link rel="manifest" href="/manifest.webmanifest">',
    '<link rel="icon" href="/icons/icon-192.png">',
    '<link rel="apple-touch-icon" href="/icons/icon-192.png">',
    '<meta name="apple-mobile-web-app-capable" content="yes">',
    '<script src="/vendor/supabase-2.117.3.js"></script>',
    '<script src="/central.js"></script>',
]
for t in tira:
    assert html.count(t) == 1, t
    html = html.replace(t, "")

inicio = "<script>\nconst cUse="
assert html.count(inicio) == 1
assert "</script" not in edicao
html = html.replace(inicio, "<script>\n" + edicao + "</script>\n" + inicio)

saida = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else raiz / "dist" / "claude.html"
saida.parent.mkdir(parents=True, exist_ok=True)
saida.write_text(html, encoding="utf8")
print(saida)

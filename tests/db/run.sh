#!/usr/bin/env bash
# Sobe um Postgres temporário, aplica as migrações da Central e roda os testes de banco (RLS, histórico, lixeira).
# Uso: tests/db/run.sh   (precisa de PostgreSQL 15+ instalado; não toca no Supabase de produção)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}
[ -x "$BIN/initdb" ] || { echo "PostgreSQL não encontrado (defina PG_BIN)"; exit 2; }
TMP=$(mktemp -d)
PORT=${PG_PORT:-54329}
trap '"$BIN/pg_ctl" -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
RUN=""; [ "$(id -u)" = 0 ] && { chown -R postgres "$TMP"; RUN="runuser -u postgres --"; }
$RUN "$BIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
$RUN "$BIN/pg_ctl" -D "$TMP/data" -o "-p $PORT -k $TMP -c listen_addresses='' -c wal_level=logical" -l "$TMP/log" -w start >/dev/null
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$TMP" -p "$PORT" -U postgres -d postgres)
"${PSQL[@]}" -f tests/db/supabase-stub.sql
for f in supabase/001_central.sql supabase/003_historico.sql supabase/004_relacional.sql; do "${PSQL[@]}" -f "$f"; done
falhou=0
for t in ${TESTES:-tests/db/*.test.sql}; do
  if "${PSQL[@]}" ${SAIDA:--o /dev/null} -f "$t"; then echo "ok   $t"; else echo "FALHOU $t"; falhou=1; fi
done
exit $falhou

#!/usr/bin/env bash
# Suíte NUB-RD-92 (demografia inferida por cota) no DEV (yfgciamhzjvarwgzosto),
# numa ÚNICA transação que SEMPRE termina em exceção: seed, migration e
# leituras nunca persistem. Sucesso = mensagem NUBRD92_ALL_PASS.
#
#   bash supabase/tests/demographics_quota/run_dev.sh        # GREEN
#   bash supabase/tests/demographics_quota/run_dev.sh red    # sem a migration: deve falhar
#
# Ordem: guarda DEV → fixture.sql (seed @qa-s9.invalid) → baseline.sql (RPC
# vigente) → migration 20261019170042 → assert.sql → RAISE. Pré-requisitos no
# DEV: 20261015204255, 20261015202330 e 20261016140000 aplicadas; Supabase CLI
# autenticado (npx supabase@2.121.0 login).
set -euo pipefail
cd "$(dirname "$0")/../../.."

REF=yfgciamhzjvarwgzosto
MODE=${1:-green}
DIR=supabase/tests/demographics_quota
MIGRATION=supabase/migrations/20261019170042_demographics_quota_inferred.sql
q() { npx -y supabase@2.121.0 db query --linked --project-ref "$REF" "$@"; }

# Confere o alvo com o MESMO comando antes de mandar qualquer escrita.
target=$(q -o json "select count(*) as n from cron.job" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).rows[0].n))')
if [ "$target" != "1" ]; then echo "ABORTADO: alvo não é o DEV (cron.job=$target)" >&2; exit 2; fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
  echo "BEGIN;"
  cat "$DIR/fixture.sql"
  cat "$DIR/baseline.sql"
  if [ "$MODE" != red ]; then cat "$MIGRATION"; fi
  cat "$DIR/assert.sql"
  echo "DO \$\$ BEGIN RAISE EXCEPTION 'NUBRD92_ALL_PASS (%): %', (SELECT count(*) FROM nubrd92_log), (SELECT string_agg(msg, ' | ' ORDER BY n) FROM nubrd92_log); END \$\$;"
} > "$tmp"
if grep -inE '^[[:space:]]*(commit|end[[:space:]]+transaction)[[:space:]]*;' "$tmp"; then
  echo "ABORTADO: o bundle contém controle de transação que persistiria dados" >&2; exit 3
fi

out=$(q -f "$tmp" 2>&1 || true)
if grep -q 'NUBRD92_ALL_PASS' <<<"$out"; then
  grep -o 'NUBRD92_ALL_PASS[^"]*' <<<"$out" | sed 's/ | /\n  ✓ /g'
  exit 0
fi
echo "$out" | grep -oE '(NUBRD92_[A-Z]+|ERROR)[^"]{0,2000}' | head -5
exit 1

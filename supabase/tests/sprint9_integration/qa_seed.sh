#!/usr/bin/env bash
# Popula (ou remove) a massa de QA da Sprint 9.0 no DEV. Persiste de propósito.
#   bash supabase/tests/sprint9_integration/qa_seed.sh          # limpa a rodada anterior e recria
#   bash supabase/tests/sprint9_integration/qa_seed.sh cleanup  # só remove
set -euo pipefail
cd "$(dirname "$0")"
REF=yfgciamhzjvarwgzosto
n=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -o json "select count(*) n from cron.job" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).rows[0].n))')
[ "$n" = 1 ] || { echo "ABORTADO: alvo não é o DEV (cron.job=$n)" >&2; exit 2; }
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{ echo "BEGIN;"; cat qa_cleanup.sql; [ "${1:-}" = cleanup ] || cat qa_seed.sql; echo "COMMIT;"; } > "$tmp"
out=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -o json -f "$tmp" 2>&1) || { echo "$out" | grep -oE 'ERROR[^"]{0,400}' | head -3; exit 1; }
echo "ok (${1:-seed})"

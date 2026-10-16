#!/usr/bin/env bash
# Roda o teste SQL do Complemento TP-1 no DEV (yfgciamhzjvarwgzosto) numa única
# transação que SEMPRE termina em exceção: fixtures, DDL e reversão nunca
# persistem. Sucesso = mensagem TP1C_ALL_PASS; qualquer outra coisa é falha.
#
#   bash supabase/tests/command-center-match-demographics/run_dev.sh         # GREEN
#   bash supabase/tests/command-center-match-demographics/run_dev.sh red     # sem a migration
set -euo pipefail
cd "$(dirname "$0")/../../.."

REF=yfgciamhzjvarwgzosto
MODE=${1:-green}
DIR=supabase/tests/command-center-match-demographics
NEW=supabase/migrations/20261015204255_command_center_match_demographics_views.sql
OLD=supabase/migrations/20260811160000_command_center_health_demographics.sql
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  echo "BEGIN;"
  if [ "$MODE" != red ]; then cat "$NEW"; fi
  cat "$DIR/assert.sql"
  cat "$OLD"
  cat "$DIR/rollback_drop_views.sql"
  cat "$DIR/assert_rollback.sql"
  echo "DO \$\$ BEGIN RAISE EXCEPTION 'TP1C_ALL_PASS (%): %', (SELECT count(*) FROM tp1c_log), (SELECT string_agg(msg, ' | ' ORDER BY n) FROM tp1c_log); END \$\$;"
} > "$tmp"

out=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -f "$tmp" 2>&1 || true)
if grep -q 'TP1C_ALL_PASS' <<<"$out"; then
  grep -o 'TP1C_ALL_PASS[^"]*' <<<"$out" | sed 's/ | /\n  ✓ /g'
  exit 0
fi
echo "$out" | grep -E 'TP1C_|ERROR|error' | head -20
exit 1

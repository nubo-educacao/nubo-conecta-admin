#!/usr/bin/env bash
# Teste dos filtros de campanha/divulgador (first-touch) do Command Center:
# migration 20261016140000_command_center_attribution_filters.sql.
#
# Roda no DEV (yfgciamhzjvarwgzosto) numa ÚNICA transação que SEMPRE termina
# em exceção: fixtures → baseline com as funções ANTIGAS → migration →
# asserções → RAISE 'CCAF_ALL_PASS …' ou 'CCAF_FAIL …'. Nada persiste. O CLI
# mostra erro mesmo no sucesso; leia a mensagem. Nunca aponte para produção
# (fixture.sql também recusa ambientes com >1000 perfis).
#
#   bash supabase/tests/command_center_attribution_filters/run_dev.sh             # GREEN
#   bash supabase/tests/command_center_attribution_filters/run_dev.sh red         # sem a migration: deve falhar
#   bash supabase/tests/command_center_attribution_filters/run_dev.sh --with-tp7  # se o DEV ainda não tem
#        os helpers de 20261015202330 (matches_first_touch_attribution/assert_attribution_filter)
#
# Pré-requisitos no DEV: 20261009203000 e 20261015204255 aplicadas (as views de
# Match/demografia) e Supabase CLI autenticado (npx supabase@2.121.0 login).
#
# Para conferir que o teste pega regressões: troque first_touch_link_id por
# last_touch_link_id no JOIN de matches_first_touch_attribution, ou remova o
# `e.user_id IS NOT NULL` — verificações de campanha B / sem atribuição falham.
set -euo pipefail
cd "$(dirname "$0")/../../.."

REF=yfgciamhzjvarwgzosto
MODE=${1:-green}
DIR=supabase/tests/command_center_attribution_filters
MIGRATION=supabase/migrations/20261016140000_command_center_attribution_filters.sql
TP7=supabase/migrations/20261015202330_tp7_first_touch_attribution_filters.sql
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  echo "BEGIN;"
  # recusa qualquer alvo que não seja o DEV (PROD tem 2 jobs de cron)
  echo "DO \$\$ BEGIN IF (SELECT count(*) FROM cron.job) <> 1 THEN RAISE EXCEPTION 'CCAF_ABORT: alvo não é o DEV'; END IF; END \$\$;"
  cat "$DIR/fixture.sql"
  cat "$DIR/baseline.sql"
  if [ "$MODE" = "--with-tp7" ]; then cat "$TP7"; fi
  cat <<'SQL'
DO $pre$ BEGIN
  IF to_regprocedure('public.matches_first_touch_attribution(uuid,uuid,uuid,boolean)') IS NULL
     OR to_regprocedure('public.assert_attribution_filter(uuid,uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'CCAF_FAIL pré-requisito: helpers do TP-7 (20261015202330) ausentes; rode com --with-tp7';
  END IF;
END $pre$;
SQL
  if [ "$MODE" != "red" ]; then cat "$MIGRATION"; fi
  cat "$DIR/assert.sql"
  echo "ROLLBACK;"
} > "$tmp"

out=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -f "$tmp" 2>&1 || true)
if grep -q 'CCAF_ALL_PASS' <<<"$out"; then
  grep -o 'CCAF_ALL_PASS[^"]*' <<<"$out"
  exit 0
fi
echo "$out" | grep -E 'CCAF_|ERROR|error' | sed 's/ | /\n  ✗ /g' | head -40
exit 1

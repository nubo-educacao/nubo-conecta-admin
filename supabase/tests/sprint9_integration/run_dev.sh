#!/usr/bin/env bash
# Integração da Sprint 9.0 no DEV (yfgciamhzjvarwgzosto), numa única transação
# que SEMPRE termina em exceção: nada persiste. Sucesso = S9_ALL_PASS.
#
#   bash supabase/tests/sprint9_integration/run_dev.sh          # GREEN: pendentes + asserções
#   bash supabase/tests/sprint9_integration/run_dev.sh red      # RED: sem as migrations de reconciliação/guard
#   bash supabase/tests/sprint9_integration/run_dev.sh plan     # só lista o que está pendente no DEV
#
# "Pendente" = arquivo da árvore cuja versão não está em
# supabase_migrations.schema_migrations do DEV, aplicado em ordem de versão (o
# mesmo conjunto que `db push --include-all` aplicaria, sem usá-lo). As
# migrations da sprint que o DEV já tem são reaplicadas na mesma transação e
# as definições comparadas: idênticas = o DEV roda o que está no Git.
set -euo pipefail
cd "$(dirname "$0")/../../.."

REF=yfgciamhzjvarwgzosto
MODE=${1:-green}
DIR=supabase/tests/sprint9_integration
RED_SKIP=${RED_SKIP:-'20261016135100|20261016135200'}
REPLAY=(
  supabase/migrations/20261009193000_tp2_residual_engagement_dashboards.sql
  supabase/migrations/20261009194500_tp2_portal_redirect_wrapper.sql
  supabase/migrations/20261009195500_tp2_guard_missing_role.sql
  supabase/migrations/20261015202041_cron_check_deadlines_vault.sql
)
# Migrations com BEGIN;/COMMIT; de topo (193000, 195500) teriam o COMMIT
# persistindo o bundle: só essas linhas de controle são removidas.
emit() { sed -E '/^[[:space:]]*(BEGIN|COMMIT)[[:space:]]*;[[:space:]]*$/Id' "$1"; }
q() { npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -o json "$@"; }

target=$(q "select count(*) as n from cron.job" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).rows[0].n))')
if [ "$target" != "1" ]; then echo "ABORTADO: alvo não é o DEV (cron.job=$target)" >&2; exit 2; fi

applied=$(q "select version from supabase_migrations.schema_migrations" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s).rows.forEach(r=>console.log(r.version)))')
pending=()
for f in supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -c1-14)
  grep -qx "$v" <<<"$applied" || pending+=("$f")
done
if [ "$MODE" = plan ]; then printf '%s\n' "${pending[@]}"; exit 0; fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
fp="SELECT p.oid::regprocedure::text AS obj, md5(replace(p.prosrc, chr(13), '') || coalesce(array_to_string(p.proconfig, ','), '') || p.prosecdef::text) AS h
      FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('get_tp2_partner_funnel','get_partner_redirect_users','get_mec_engagement_dashboard',
                         'get_partner_institution_redirect_users','cron_check_deadlines','cron_deadlines_secret_status')
     UNION ALL
    SELECT 'view:' || c.relname, md5(pg_get_viewdef(c.oid)) FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relname = 'vw_partner_funnel'"
{
  echo "BEGIN;"
  echo "DO \$\$ BEGIN IF (SELECT count(*) FROM cron.job) <> 1 THEN RAISE EXCEPTION 'S9_ABORT: não é o DEV'; END IF; END \$\$;"
  for f in "${pending[@]}"; do
    if [ "$MODE" = red ] && grep -qE "$RED_SKIP" <<<"$f"; then continue; fi
    echo "-- >>> $f"; emit "$f"; echo
  done
  echo "CREATE TEMP TABLE s9_fp_before ON COMMIT DROP AS $fp;"
  for f in "${REPLAY[@]}"; do echo "-- >>> replay $f"; emit "$f"; echo; done
  echo "DO \$\$ DECLARE v text; BEGIN
    SELECT string_agg(coalesce(b.obj, a.obj), ', ') INTO v
      FROM s9_fp_before b FULL JOIN ($fp) a USING (obj) WHERE b.h IS DISTINCT FROM a.h;
    IF v IS NOT NULL THEN RAISE EXCEPTION 'S9_FAIL: DEV difere do Git em %', v; END IF;
  END \$\$;"
  cat "$DIR/assert.sql"
  echo "DO \$\$ BEGIN RAISE EXCEPTION 'S9_ALL_PASS (%): replay idêntico | %', (SELECT count(*) FROM s9_log), (SELECT string_agg(msg, ' | ' ORDER BY n) FROM s9_log); END \$\$;"
} > "$tmp"
if grep -inE '^[[:space:]]*(commit|rollback|end[[:space:]]+transaction)[[:space:]]*;' "$tmp" | grep -v "RAISE" ; then
  echo "ABORTADO: o bundle contém controle de transação que persistiria dados" >&2; exit 3
fi

echo "pendentes no DEV (${#pending[@]}):"; printf '  %s\n' "${pending[@]##*/}"
out=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -f "$tmp" 2>&1 || true)
if grep -q 'S9_ALL_PASS' <<<"$out"; then
  grep -o 'S9_ALL_PASS[^"]*' <<<"$out" | sed 's/ | /\n  ✓ /g'
  exit 0
fi
echo "$out" | grep -oE '(S9_[A-Z]+|ERROR)[^"]{0,400}' | head -5; echo "$out" | grep -iE "detail|constraint|foreign" | head -5
exit 1

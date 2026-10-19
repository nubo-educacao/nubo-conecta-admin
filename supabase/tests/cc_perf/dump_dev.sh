#!/usr/bin/env bash
# Dump SOMENTE LEITURA das tabelas que as Edges analytics-* leem, a partir do
# DEV (yfgciamhzjvarwgzosto), para o oráculo diferencial:
#
#   bash supabase/tests/cc_perf/dump_dev.sh /caminho/fora/do/repo/dev.json
#   node supabase/tests/cc_perf/differential.mjs --data /caminho/fora/do/repo/dev.json
#
# O arquivo tem nomes e cidades de perfis: grave FORA do repositório e apague
# depois. Recusa qualquer alvo que não seja o DEV (cron.job = 1; PROD tem 2).
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:?uso: dump_dev.sh <arquivo de saída fora do repo>}
REF=yfgciamhzjvarwgzosto
q() { npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -o json "$@"; }
sql=$(mktemp)
trap 'rm -f "$sql"' EXIT

target=$(q "select count(*) as n from cron.job" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).rows[0].n))')
if [ "$target" != "1" ]; then echo "ABORTADO: alvo não é o DEV (cron.job=$target)" >&2; exit 2; fi

cat > "$sql" <<'SQL'
select json_build_object(
  'channel_links',    (select coalesce(json_agg(t), '[]') from (select id, campaign_id, channel_id, archived_at from public.channel_links) t),
  'user_attribution', (select coalesce(json_agg(t), '[]') from (select user_id, first_touch_link_id, last_touch_link_id from public.user_attribution) t),
  'user_profiles',    (select coalesce(json_agg(t), '[]') from (select id, full_name, city from public.user_profiles) t),
  'chat_messages',    (select coalesce(json_agg(t), '[]') from (select id, user_id, sender, created_at from public.chat_messages) t),
  'user_favorites',   (select coalesce(json_agg(t), '[]') from (select id, user_id, created_at from public.user_favorites) t),
  'user_preferences', (select coalesce(json_agg(t), '[]') from (select id, user_id, updated_at, course_interest, program_preference, location_preference from public.user_preferences) t)
)::text as d
SQL
q -f "$sql" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).rows[0].d))' > "$OUT"
node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(Object.entries(d).map(([k,v])=>k+"="+v.length).join(" "))' "$OUT"

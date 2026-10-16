#!/usr/bin/env bash
# Roda o teste de filtros first-touch no DEV, numa única transação que SEMPRE
# termina em exceção (TP7_ALL_PASS ou TP7_FAIL) — migration e fixtures são
# desfeitas. Nunca aponte para produção.
#
#   bash supabase/tests/attribution_filters/run-dev.sh          # GREEN: com a migration
#   bash supabase/tests/attribution_filters/run-dev.sh --red    # RED: sem a migration
set -euo pipefail

DEV_REF="yfgciamhzjvarwgzosto"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MIGRATION="$ROOT/supabase/migrations/20261015202330_tp7_first_touch_attribution_filters.sql"
BUNDLE="$(mktemp -t tp7-attribution-XXXXXX.sql)"
trap 'rm -f "$BUNDLE"; (cd "$ROOT" && npx --no-install supabase unlink >/dev/null 2>&1 || true)' EXIT

{
  echo "BEGIN;"
  cat "$HERE/fixture.sql"
  cat "$HERE/baseline.sql"
  if [[ "${1:-}" != "--red" ]]; then cat "$MIGRATION"; fi
  cat "$HERE/assert.sql"
  echo "ROLLBACK;"
} > "$BUNDLE"

cd "$ROOT"
npx --no-install supabase link --project-ref "$DEV_REF" >/dev/null
linked="$(cat supabase/.temp/project-ref)"
if [[ "$linked" != "$DEV_REF" ]]; then
  echo "ABORTADO: link aponta para '$linked', não para o DEV ($DEV_REF)." >&2
  exit 2
fi

npx --no-install supabase db query --linked --agent=no -f "$BUNDLE" 2>&1 || true

#!/usr/bin/env bash
# NUB-RD-86 — confere, ANTES do deploy, a saída do `vercel build` do admin (Vite).
#
# Uso: verify-build-output.sh <supabase-ref-esperado> <supabase-ref-proibido>
#
# Nos assets JS do Vite (onde entram as VITE_*):
#   - o ref do Supabase do ambiente certo aparece; o do outro, nunca;
#   - nenhuma chave secreta do Supabase (sb_secret_);
#   - o VALOR de GOVERNANCE_API_KEY (se estiver no ambiente do job) não aparece:
#     a chave do Snaps é só do servidor (proxy /api/snaps).
# Só imprime refs públicos e contagens; nunca o valor da chave.
set -euo pipefail

sb_ok="$1"; sb_bad="$2"
assets=".vercel/output/static/assets"
[ -d "$assets" ] || { echo "::error::$assets não existe: o build não rodou"; exit 1; }

falhas=0
# `grep` sem ocorrência sai com 1; com pipefail isso derrubaria o script em silêncio.
conta() { { grep -rlF -- "$1" "$assets" 2>/dev/null || true; } | wc -l | tr -d ' '; }

n=$(conta "$sb_ok.supabase.co");  echo "Supabase esperado $sb_ok nos assets: $n";  [ "$n" -gt 0 ] || { echo "::error::$sb_ok ausente dos assets"; falhas=1; }
n=$(conta "$sb_bad.supabase.co"); echo "Supabase proibido $sb_bad nos assets: $n"; [ "$n" -eq 0 ] || { echo "::error::$sb_bad presente nos assets"; falhas=1; }
n=$(conta "sb_secret_");          echo "sb_secret nos assets: $n";                 [ "$n" -eq 0 ] || { echo "::error::chave secreta do Supabase nos assets"; falhas=1; }
if [ -n "${GOVERNANCE_API_KEY:-}" ]; then
  n=$(conta "$GOVERNANCE_API_KEY");    echo "chave do Snaps nos assets: $n";            [ "$n" -eq 0 ] || { echo "::error::a chave do Snaps vazou para o bundle"; falhas=1; }
fi

exit "$falhas"

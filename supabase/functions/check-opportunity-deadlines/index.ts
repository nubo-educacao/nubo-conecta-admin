// Edge Function: check-opportunity-deadlines — Sprint 6, ADR-0024
// Chamada diariamente por public.cron_check_deadlines() (pg_cron, job
// 'check-program-deadlines'). Gera alertas pending em admin_alerts para o
// Action Center; regras e autenticação em ./core.ts.
//
// Autenticação: header x-cron-secret, comparado com o segredo do Vault
// (cron_check_deadlines_secret). verify_jwt = false em supabase/config.toml.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { handleDeadlineRequest } from './core.ts';

Deno.serve((req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  return handleDeadlineRequest(req, supabase);
});

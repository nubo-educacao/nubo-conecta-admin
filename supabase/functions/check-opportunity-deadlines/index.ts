// Edge Function: check-opportunity-deadlines — Sprint 6
// Cron job que verifica deadlines de oportunidades e gera alertas no admin_alerts.
//
// Logica:
//   1. Partner opportunities com ends_at dentro de 7 dias → alerta 'opportunity_expiring'
//   2. important_dates com controls_opportunity_dates=true e start_date dentro de 3 dias → 'mec_period_start'
//   3. important_dates com controls_opportunity_dates=true e end_date no passado → 'mec_period_end'
//
// Deduplicacao: nao cria alerta se ja existe pending com mesmo entity_type + entity_id + alert_type.
// Executar via cron (supabase) ou manualmente para testes.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface AlertInput {
  alert_type: string;
  severity: string;
  title: string;
  description: string;
  entity_type: string;
  entity_id: string;
  action_label?: string;
  action_type?: string;
  action_metadata?: Record<string, unknown>;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const now = new Date();
  const alerts: AlertInput[] = [];

  // 1. Partner opportunities expirando em 7 dias
  const sevenDaysFromNow = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data: expiringOpps } = await supabase
    .from('partner_opportunities')
    .select('id, name, ends_at, status')
    .eq('status', 'approved')
    .not('ends_at', 'is', null)
    .lte('ends_at', sevenDaysFromNow)
    .gte('ends_at', now.toISOString());

  for (const opp of expiringOpps ?? []) {
    const daysLeft = Math.ceil(
      (new Date(opp.ends_at).getTime() - now.getTime()) / (1000 * 60 * 60 * 24),
    );
    alerts.push({
      alert_type: 'opportunity_expiring',
      severity: daysLeft <= 2 ? 'critical' : 'warning',
      title: `Oportunidade "${opp.name}" expira em ${daysLeft} dia${daysLeft !== 1 ? 's' : ''}`,
      description: `A oportunidade parceira encerrara inscricoes em ${new Date(opp.ends_at).toLocaleDateString('pt-BR')}.`,
      entity_type: 'partner_opportunity',
      entity_id: opp.id,
      action_label: 'Ver oportunidade',
      action_type: 'navigate',
      action_metadata: { route: '/partner-opportunities' },
    });
  }

  // 2. MEC periods abrindo em 3 dias
  const threeDaysFromNow = new Date(now.getTime() + 3 * 24 * 60 * 60 * 1000).toISOString();
  const { data: mecDates } = await supabase
    .from('important_dates')
    .select('id, title, type, start_date, end_date')
    .eq('controls_opportunity_dates', true);

  for (const d of mecDates ?? []) {
    const startDate = new Date(d.start_date);
    const daysUntilStart = Math.ceil((startDate.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));

    if (daysUntilStart > 0 && daysUntilStart <= 3) {
      alerts.push({
        alert_type: 'mec_period_start',
        severity: 'info',
        title: `Periodo ${d.type.toUpperCase()} abre em ${daysUntilStart} dia${daysUntilStart !== 1 ? 's' : ''}`,
        description: `"${d.title}" — inscricoes abrem em ${startDate.toLocaleDateString('pt-BR')}.`,
        entity_type: 'important_date',
        entity_id: d.id,
        action_label: 'Ver calendario',
        action_type: 'navigate',
        action_metadata: { route: '/calendar' },
      });
    }

    // 3. MEC period encerrado
    if (d.end_date) {
      const endDate = new Date(d.end_date);
      const daysSinceEnd = Math.ceil((now.getTime() - endDate.getTime()) / (1000 * 60 * 60 * 24));

      if (daysSinceEnd >= 0 && daysSinceEnd <= 1) {
        alerts.push({
          alert_type: 'mec_period_end',
          severity: 'warning',
          title: `Periodo ${d.type.toUpperCase()} encerrou`,
          description: `"${d.title}" — inscricoes encerraram em ${endDate.toLocaleDateString('pt-BR')}.`,
          entity_type: 'important_date',
          entity_id: d.id,
          action_label: 'Ver calendario',
          action_type: 'navigate',
          action_metadata: { route: '/calendar' },
        });
      }
    }
  }

  // Deduplicacao: verificar alertas pending existentes
  let inserted = 0;
  for (const alert of alerts) {
    const { data: existing } = await supabase
      .from('admin_alerts')
      .select('id')
      .eq('alert_type', alert.alert_type)
      .eq('entity_type', alert.entity_type)
      .eq('entity_id', alert.entity_id)
      .eq('status', 'pending')
      .limit(1);

    if (existing && existing.length > 0) continue;

    const { error } = await supabase.from('admin_alerts').insert(alert);
    if (!error) inserted++;
  }

  return new Response(
    JSON.stringify({
      checked: {
        expiring_opportunities: expiringOpps?.length ?? 0,
        mec_dates: mecDates?.length ?? 0,
      },
      alerts_generated: alerts.length,
      alerts_inserted: inserted,
      alerts_deduplicated: alerts.length - inserted,
    }),
    { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});

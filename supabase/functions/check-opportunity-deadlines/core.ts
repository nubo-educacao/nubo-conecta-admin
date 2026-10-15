// Núcleo da Edge Function check-opportunity-deadlines — ADR-0024 / NUB-RD-75c.
//
// Sem imports de Deno ou esm.sh para que o vitest exercite o contrato real.
// As regras de janela (o que vira alerta) são as mesmas da Sprint 6; este
// arquivo só muda três coisas:
//   1. Autenticação: o chamador prova conhecer o segredo dedicado do cron
//      (header x-cron-secret), validado contra o Supabase Vault pela RPC
//      cron_deadlines_secret_status. verify_jwt fica desligado nesta função,
//      senão qualquer JWT válido — inclusive a anon key pública — dispararia
//      uma função que roda com service_role.
//   2. Falha explícita: erro de leitura/insert vira HTTP 500. Antes, `data`
//      nulo virava lista vazia e a resposta era 200 com zeros — sucesso vazio.
//   3. Dedupe: o índice único parcial em admin_alerts (pending) é a garantia;
//      23505 no insert conta como deduplicado.

export interface DbError {
  code?: string;
  message: string;
}

interface QueryResult<T> {
  data: T | null;
  error: DbError | null;
}

// Subconjunto do SupabaseClient usado aqui; tipado frouxo de propósito para
// aceitar tanto o client real quanto o fake do teste.
export interface DeadlineClient {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<QueryResult<unknown>>;
  // deno-lint-ignore no-explicit-any
  from: (table: string) => any;
}

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

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

const VAULT_SECRET_NAME = 'cron_check_deadlines_secret';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

class DeadlineCheckError extends Error {}

function must<T>(result: QueryResult<T>, what: string): T {
  if (result.error) {
    throw new DeadlineCheckError(`falha ao ler ${what}: ${result.error.message}`);
  }
  return result.data ?? ([] as unknown as T);
}

export async function handleDeadlineRequest(
  req: Request,
  supabase: DeadlineClient,
  now: Date = new Date(),
): Promise<Response> {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const secret = req.headers.get('x-cron-secret');
  if (!secret) {
    return json(401, { error: 'x-cron-secret ausente' });
  }

  const auth = await supabase.rpc('cron_deadlines_secret_status', { p_secret: secret });
  if (auth.error) {
    return json(500, { error: `falha ao validar segredo do cron: ${auth.error.message}` });
  }
  if (auth.data === 'not_configured') {
    return json(503, {
      error: `segredo do cron não provisionado no Vault (${VAULT_SECRET_NAME})`,
    });
  }
  if (auth.data !== 'ok') {
    return json(401, { error: 'x-cron-secret inválido' });
  }

  try {
    return json(200, await generateAlerts(supabase, now));
  } catch (err) {
    const message = err instanceof DeadlineCheckError ? err.message : `erro inesperado: ${String(err)}`;
    return json(500, { error: message });
  }
}

async function generateAlerts(supabase: DeadlineClient, now: Date) {
  const alerts: AlertInput[] = [];

  // 1. Partner opportunities expirando em 7 dias
  const sevenDaysFromNow = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const expiringOpps = must<Array<{ id: string; name: string; ends_at: string }>>(
    await supabase
      .from('partner_opportunities')
      .select('id, name, ends_at, status')
      .eq('status', 'approved')
      .not('ends_at', 'is', null)
      .lte('ends_at', sevenDaysFromNow)
      .gte('ends_at', now.toISOString()),
    'partner_opportunities',
  );

  for (const opp of expiringOpps) {
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
  const mecDates = must<
    Array<{ id: string; title: string; type: string; start_date: string; end_date: string | null }>
  >(
    await supabase
      .from('important_dates')
      .select('id, title, type, start_date, end_date')
      .eq('controls_opportunity_dates', true),
    'important_dates',
  );

  for (const d of mecDates) {
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

  // 4. Program deadlines (incoming starting in 3 days, opened ending in past)
  const programs = must<
    Array<{ id: string; title: string; status: string; starts_at: string | null; ends_at: string | null }>
  >(
    await supabase.from('programs').select('id, title, type, status, starts_at, ends_at'),
    'programs',
  );

  for (const prog of programs) {
    if (prog.status === 'incoming' && prog.starts_at) {
      const startDate = new Date(prog.starts_at);
      const daysUntilStart = Math.ceil((startDate.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));

      if (daysUntilStart > 0 && daysUntilStart <= 3) {
        alerts.push({
          alert_type: 'program_start_incoming',
          severity: 'info',
          title: `Deseja abrir o programa ${prog.title}?`,
          description: `As inscrições para o programa ${prog.title} abrem em ${startDate.toLocaleDateString('pt-BR')}.`,
          entity_type: 'program',
          entity_id: prog.id,
          action_label: 'Confirmar',
          action_type: 'update_program_status',
          action_metadata: { status: 'opened' },
        });
      }
    }

    if (prog.status === 'opened' && prog.ends_at) {
      const endDate = new Date(prog.ends_at);

      if (endDate < now) {
        alerts.push({
          alert_type: 'program_end_opened',
          severity: 'warning',
          title: `Programa ${prog.title} expirou`,
          description: `As inscrições para o programa ${prog.title} encerraram em ${endDate.toLocaleDateString('pt-BR')}. Deseja alterar o status para encerrado?`,
          entity_type: 'program',
          entity_id: prog.id,
          action_label: 'Confirmar',
          action_type: 'update_program_status',
          action_metadata: { status: 'closed' },
        });
      }
    }
  }

  // Deduplicacao: o SELECT evita o insert no caso comum; o índice único
  // parcial (status = 'pending') garante sob concorrência — 23505 = já existe.
  let inserted = 0;
  for (const alert of alerts) {
    const existing = must<Array<{ id: string }>>(
      await supabase
        .from('admin_alerts')
        .select('id')
        .eq('alert_type', alert.alert_type)
        .eq('entity_type', alert.entity_type)
        .eq('entity_id', alert.entity_id)
        .eq('status', 'pending')
        .limit(1),
      'admin_alerts',
    );

    if (existing.length > 0) continue;

    const { error } = await supabase.from('admin_alerts').insert(alert);
    if (error?.code === '23505') continue;
    if (error) {
      throw new DeadlineCheckError(`falha ao inserir admin_alert ${alert.alert_type}: ${error.message}`);
    }
    inserted++;
  }

  return {
    checked: {
      expiring_opportunities: expiringOpps.length,
      mec_dates: mecDates.length,
      programs: programs.length,
    },
    alerts_generated: alerts.length,
    alerts_inserted: inserted,
    alerts_deduplicated: alerts.length - inserted,
  };
}

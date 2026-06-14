/**
 * migrate-dev-to-prod.ts
 * ========================
 * Migração de dados do banco Dev (nubo-hub) para Prod (nubo-hub-prod).
 * Plano: ca81e337 | Sprint: 5012b6f8 | ADR: ADR-0021
 *
 * Pré-requisitos:
 *   1. Backup manual de Prod já feito (snapshot Supabase ou pg_dump)
 *   2. supabase db push já executado em Prod (Card 1)
 *   3. Variáveis de ambiente configuradas (ver abaixo)
 *
 * Execução:
 *   npx tsx scripts/migrate-dev-to-prod.ts
 *
 * Variáveis de ambiente necessárias:
 *   DEV_SUPABASE_URL          URL do projeto dev (nubo-hub)
 *   DEV_SUPABASE_SERVICE_KEY  Service role key do dev
 *   PROD_SUPABASE_URL         URL do projeto prod (nubo-hub-prod)
 *   PROD_SUPABASE_SERVICE_KEY Service role key do prod
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js';

const DEV_URL = process.env.DEV_SUPABASE_URL!;
const DEV_KEY = process.env.DEV_SUPABASE_SERVICE_KEY!;
const PROD_URL = process.env.PROD_SUPABASE_URL!;
const PROD_KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;

const PAGE_SIZE = 500;

function log(msg: string) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

function assertEnv() {
  const missing = ['DEV_SUPABASE_URL', 'DEV_SUPABASE_SERVICE_KEY', 'PROD_SUPABASE_URL', 'PROD_SUPABASE_SERVICE_KEY']
    .filter(k => !process.env[k]);
  if (missing.length > 0) throw new Error(`Variáveis faltando: ${missing.join(', ')}`);
}

async function deleteAll(prod: SupabaseClient, table: string, pkColumn = 'id') {
  log(`  TRUNCATE ${table}...`);
  const { error } = await prod
    .from(table)
    .delete()
    .neq(pkColumn, '00000000-0000-0000-0000-000000000000');
  if (error) throw new Error(`Falha ao truncar ${table}: ${error.message}`);
  log(`  ✓ ${table} truncado`);
}

async function upsertTable(
  dev: SupabaseClient,
  prod: SupabaseClient,
  table: string,
  options: {
    orderBy?: string;
    onConflict?: string;
    transform?: (rows: Record<string, unknown>[]) => Record<string, unknown>[];
  } = {}
) {
  const { orderBy = 'created_at', onConflict = 'id', transform } = options;
  log(`  Upsertando ${table}...`);

  let page = 0;
  let total = 0;

  while (true) {
    const { data, error } = await dev
      .from(table)
      .select('*')
      .order(orderBy)
      .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);

    if (error) throw new Error(`Erro ao ler ${table} (p${page}): ${error.message}`);
    if (!data || data.length === 0) break;

    const rows = transform ? transform(data as Record<string, unknown>[]) : data;

    const { error: upsertError } = await prod
      .from(table)
      .upsert(rows as Record<string, unknown>[], { onConflict });

    if (upsertError) throw new Error(`Erro ao upsert ${table} (p${page}): ${upsertError.message}`);

    total += rows.length;
    log(`    → ${total} em ${table}`);

    if (data.length < PAGE_SIZE) break;
    page++;
  }

  log(`  ✓ ${table}: ${total} registros`);
  return total;
}

async function count(prod: SupabaseClient, table: string): Promise<number> {
  const { count, error } = await prod.from(table).select('*', { count: 'exact', head: true });
  if (error) throw new Error(`Erro ao contar ${table}: ${error.message}`);
  return count ?? 0;
}

// ---------------------------------------------------------------------------
// Passo 1 — TRUNCATE
// Limpa tabelas educacionais E programs em prod antes de upsert de dev.
//
// POR QUE truncar programs:
//   O `supabase db push` cria programs com UUIDs gerados em prod (diferentes
//   dos de dev). Sem truncate, os programs de prod e de dev coexistem com
//   status divergentes, e a v_unified_opportunities (que faz JOIN por
//   programs.type + status) exibe resultados diferentes dos de dev.
//
// NÃO truncar: partners, partner_forms, partner_steps, student_applications,
//              knowledge_documents, partners_click, partners_users, partner_solicitations
// ---------------------------------------------------------------------------

async function step1_truncate(prod: SupabaseClient) {
  log('\n=== PASSO 1: TRUNCATE ===');

  const tables = [
    // Transacionais
    'user_favorites',
    'external_redirect_clicks',
    'passport_applications',
    // Educacionais leaf-first
    'courses_prouni_vacancies',
    'opportunities_sisu_vacancies',
    'important_dates',
    'opportunities',
    'courses',
    'campus',
    'institutions_info_emec',
    'institutions_info_sisu',
    'institutions',
    // Programs: DEVE ser truncado para que os IDs/status de dev sejam
    // os únicos em prod, garantindo v_unified_opportunities idêntica
    'programs',
  ];

  for (const table of tables) {
    try {
      await deleteAll(prod, table);
    } catch (e) {
      log(`  ⚠ Ignorando ${table}: ${(e as Error).message}`);
    }
  }

  log('✓ Passo 1 concluído');
}

// ---------------------------------------------------------------------------
// Passo 2 — UPSERT dados de dev
// Ordem root-first para respeitar FKs
// ---------------------------------------------------------------------------

async function step2_upsert(dev: SupabaseClient, prod: SupabaseClient) {
  log('\n=== PASSO 2: UPSERT dados de Dev ===');

  // Dados educacionais MEC
  await upsertTable(dev, prod, 'institutions');
  await upsertTable(dev, prod, 'campus');
  await upsertTable(dev, prod, 'courses');
  await upsertTable(dev, prod, 'institutions_info_emec');
  await upsertTable(dev, prod, 'institutions_info_sisu');

  // Programs: os mesmos IDs e status de dev garantem v_unified_opportunities idêntica
  await upsertTable(dev, prod, 'programs');

  // Parceiro BIP Brasil
  await upsertTable(dev, prod, 'partner_institutions', { onConflict: 'institution_id' });
  await upsertTable(dev, prod, 'partner_opportunities');
  await upsertTable(dev, prod, 'partner_steps', { orderBy: 'sort_order' });
  await upsertTable(dev, prod, 'partner_forms', { orderBy: 'sort_order' });

  // Oportunidades (dependem de courses + programs já inseridos)
  await upsertTable(dev, prod, 'opportunities');
  await upsertTable(dev, prod, 'opportunities_sisu_vacancies');
  await upsertTable(dev, prod, 'courses_prouni_vacancies');
  await upsertTable(dev, prod, 'important_dates');

  // Knowledge base
  await upsertTable(dev, prod, 'knowledge_categories');
  await upsertTable(dev, prod, 'knowledge_documents');
  await upsertTable(dev, prod, 'knowledge_document_versions');
  await upsertTable(dev, prod, 'knowledge_keywords');

  // Config da plataforma
  await upsertTable(dev, prod, 'cloudinha_starters');
  await upsertTable(dev, prod, 'home_sections');
  await upsertTable(dev, prod, 'match_config', { onConflict: 'weight_key', orderBy: 'weight_key' });
  await upsertTable(dev, prod, 'agent_prompts', { onConflict: 'agent_key', orderBy: 'agent_key' });
  await upsertTable(dev, prod, 'course_groups', { onConflict: 'group_key', orderBy: 'group_key' });
  await upsertTable(dev, prod, 'system_intents');

  log('✓ Passo 2 concluído');
}

// ---------------------------------------------------------------------------
// Passo 3 — Mapear partners legados de prod → partner_institutions
// Os 6 parceiros existentes em prod (Insper, Fundação Estudar, etc.) ficam
// na tabela `partners` legada e precisam de pares no schema novo.
// ---------------------------------------------------------------------------

async function step3_mapLegacyPartners(prod: SupabaseClient) {
  log('\n=== PASSO 3: Mapear partners legados → partner_institutions ===');

  const { data: partners, error } = await prod
    .from('partners')
    .select('id, name, description, location, link, coverimage, external_redirect_config');

  if (error) throw new Error(`Erro ao ler partners: ${error.message}`);
  if (!partners?.length) { log('  ⚠ Nenhum partner legado'); return; }

  for (const partner of partners as Record<string, unknown>[]) {
    const name = partner.name as string;
    log(`  Processando: ${name}`);

    const { data: existing } = await prod
      .from('institutions').select('id').eq('name', name).eq('is_partner', true).maybeSingle();

    let institutionId: string;
    if (existing) {
      institutionId = existing.id as string;
    } else {
      const { data: inst, error: e } = await prod
        .from('institutions').insert({ name, is_partner: true }).select('id').single();
      if (e) throw new Error(`Erro ao criar institution "${name}": ${e.message}`);
      institutionId = inst.id as string;
    }

    const { data: existingPI } = await prod
      .from('partner_institutions').select('institution_id').eq('institution_id', institutionId).maybeSingle();

    if (!existingPI) {
      const { error: e } = await prod.from('partner_institutions').insert({
        institution_id: institutionId,
        description: partner.description,
        location: partner.location,
        logo_url: null,
        cover_url: partner.coverimage,
        website_url: partner.link,
        brand_color: null,
      });
      if (e) throw new Error(`Erro ao criar partner_institutions "${name}": ${e.message}`);
    }

    const { data: existingPO } = await prod
      .from('partner_opportunities').select('id').eq('institution_id', institutionId).maybeSingle();

    if (!existingPO) {
      const { error: e } = await prod.from('partner_opportunities').insert({
        institution_id: institutionId,
        name,
        description: partner.description,
        opportunity_type: 'scholarship',
        eligibility_criteria: {},
        external_redirect_config: partner.external_redirect_config ?? {},
        status: 'inactive',
      });
      if (e) throw new Error(`Erro ao criar partner_opportunities "${name}": ${e.message}`);
      log(`    → criado (status=inactive — ativar manualmente após revisão)`);
    } else {
      log(`    → já existe`);
    }
  }

  log('✓ Passo 3 concluído');
}

// ---------------------------------------------------------------------------
// Passo 4 — REFRESH Materialized View
// ---------------------------------------------------------------------------

async function step4_refresh(prod: SupabaseClient) {
  log('\n=== PASSO 4: REFRESH MATERIALIZED VIEW ===');

  const { error } = await prod.rpc('refresh_unified_opportunities');
  if (error) {
    log(`  ⚠ RPC indisponível: ${error.message}`);
    log('  → AÇÃO MANUAL no SQL Editor de prod:');
    log('    REFRESH MATERIALIZED VIEW v_unified_opportunities;');
  } else {
    log('  ✓ REFRESH executado');
  }

  log('✓ Passo 4 concluído');
}

// ---------------------------------------------------------------------------
// Passo 5 — Validação
// ---------------------------------------------------------------------------

async function step5_validate(prod: SupabaseClient) {
  log('\n=== PASSO 5: VALIDAÇÃO ===');

  const checks: Array<{ table: string; expected: number; op: '==' | '>=' }> = [
    { table: 'user_profiles',              expected: 3058,  op: '==' },
    { table: 'user_enem_scores',           expected: 606,   op: '==' },
    { table: 'user_preferences',           expected: 1270,  op: '==' },
    { table: 'user_income',                expected: 466,   op: '==' },
    { table: 'chat_messages',              expected: 42394, op: '==' },
    { table: 'partners',                   expected: 6,     op: '==' },
    { table: 'student_applications',       expected: 430,   op: '==' },
    { table: 'programs',                   expected: 6,     op: '==' },
    { table: 'institutions',               expected: 138,   op: '>=' },
    { table: 'courses',                    expected: 7539,  op: '>=' },
    { table: 'opportunities',              expected: 66289, op: '>=' },
    { table: 'partner_institutions',       expected: 1,     op: '>=' },
    { table: 'partner_opportunities',      expected: 1,     op: '>=' },
    { table: 'partner_steps',              expected: 1,     op: '>=' },
    { table: 'knowledge_categories',       expected: 6,     op: '>=' },
    { table: 'knowledge_documents',        expected: 10,    op: '>=' },
    { table: 'knowledge_document_versions',expected: 17,    op: '>=' },
    { table: 'knowledge_keywords',         expected: 54,    op: '>=' },
    { table: 'user_favorites',             expected: 0,     op: '==' },
  ];

  let passed = 0, failed = 0;

  for (const c of checks) {
    try {
      const n = await count(prod, c.table);
      const ok = c.op === '>=' ? n >= c.expected : n === c.expected;
      log(`  ${ok ? '✅' : '❌'} ${c.table}: ${n} (esperado: ${c.op} ${c.expected})`);
      ok ? passed++ : failed++;
    } catch (e) {
      log(`  ⚠ ${c.table}: ${(e as Error).message}`);
      failed++;
    }
  }

  log(`\n=== ${passed} ✅ | ${failed} ❌ ===`);
  if (failed > 0) throw new Error(`${failed} checks falharam.`);
  log('✓ Passo 5 concluído');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log('🚀 Migração Dev → Prod');
  log('⚠️  PRÉ-REQUISITO: Backup de prod feito.');
  log('⚠️  PRÉ-REQUISITO: supabase db push (Card 1) executado.');

  assertEnv();

  const dev = createClient(DEV_URL, DEV_KEY, { auth: { autoRefreshToken: false, persistSession: false } });
  const prod = createClient(PROD_URL, PROD_KEY, { auth: { autoRefreshToken: false, persistSession: false } });

  try {
    await step1_truncate(prod);
    await step2_upsert(dev, prod);
    await step3_mapLegacyPartners(prod);
    await step4_refresh(prod);
    await step5_validate(prod);

    log('\n🎉 Migração concluída!');
    log('⚠️  Ativar manualmente os partner_opportunities dos parceiros legados em /partner-opportunities.');
  } catch (err) {
    log(`\n💥 ERRO: ${(err as Error).message}`);
    process.exit(1);
  }
}

main();

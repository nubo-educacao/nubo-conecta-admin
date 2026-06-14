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
 * Variáveis de ambiente necessárias (.env.migration ou export):
 *   DEV_SUPABASE_URL          URL do projeto dev (nubo-hub)
 *   DEV_SUPABASE_SERVICE_KEY  Service role key do dev
 *   PROD_SUPABASE_URL         URL do projeto prod (nubo-hub-prod)
 *   PROD_SUPABASE_SERVICE_KEY Service role key do prod
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const DEV_URL = process.env.DEV_SUPABASE_URL!;
const DEV_KEY = process.env.DEV_SUPABASE_SERVICE_KEY!;
const PROD_URL = process.env.PROD_SUPABASE_URL!;
const PROD_KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;

const PAGE_SIZE = 500;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function log(msg: string) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

function assertEnv() {
  const missing = ['DEV_SUPABASE_URL', 'DEV_SUPABASE_SERVICE_KEY', 'PROD_SUPABASE_URL', 'PROD_SUPABASE_SERVICE_KEY']
    .filter(k => !process.env[k]);
  if (missing.length > 0) {
    throw new Error(`Variáveis de ambiente faltando: ${missing.join(', ')}`);
  }
}

async function deleteAllRows(prod: SupabaseClient, table: string, pkColumn = 'id') {
  log(`  TRUNCATE ${table}...`);
  // Delete all via neq trick (service key bypasses RLS)
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
    select?: string;
    onConflict?: string;
    transform?: (rows: Record<string, unknown>[]) => Record<string, unknown>[];
  } = {}
) {
  const { orderBy = 'created_at', select = '*', onConflict = 'id', transform } = options;
  log(`  Upsertando ${table}...`);

  let page = 0;
  let total = 0;

  while (true) {
    const from = page * PAGE_SIZE;
    const to = from + PAGE_SIZE - 1;

    const { data, error } = await dev
      .from(table)
      .select(select)
      .order(orderBy)
      .range(from, to);

    if (error) throw new Error(`Erro ao ler ${table} (página ${page}): ${error.message}`);
    if (!data || data.length === 0) break;

    const rows = transform ? transform(data as Record<string, unknown>[]) : data;

    const { error: upsertError } = await prod
      .from(table)
      .upsert(rows as Record<string, unknown>[], { onConflict });

    if (upsertError) throw new Error(`Erro ao upsert em ${table} (página ${page}): ${upsertError.message}`);

    total += rows.length;
    log(`    → ${total} registros em ${table}...`);

    if (data.length < PAGE_SIZE) break;
    page++;
  }

  log(`  ✓ ${table}: ${total} registros`);
  return total;
}

async function countProd(prod: SupabaseClient, table: string): Promise<number> {
  const { count, error } = await prod.from(table).select('*', { count: 'exact', head: true });
  if (error) throw new Error(`Erro ao contar ${table}: ${error.message}`);
  return count ?? 0;
}

// ---------------------------------------------------------------------------
// Passo 1: TRUNCATE tabelas educacionais em Prod (Passo 2.1)
// NÃO truncar: partners, partner_forms, partner_steps, student_applications,
//              knowledge_documents, partners_click, partners_users, partner_solicitations
// ---------------------------------------------------------------------------

async function step1_truncate(prod: SupabaseClient) {
  log('\n=== PASSO 1: TRUNCATE (tabelas educacionais) ===');

  const tables = [
    'user_favorites',
    'external_redirect_clicks',
    'passport_applications',
    'courses_prouni_vacancies',
    'opportunities_sisu_vacancies',
    'important_dates',
    'opportunities',
    'courses',
    'campus',
    'institutions_info_emec',
    'institutions_info_sisu',
    'institutions',
  ];

  for (const table of tables) {
    try {
      await deleteAllRows(prod, table);
    } catch (e) {
      log(`  ⚠ Ignorando ${table}: ${(e as Error).message}`);
    }
  }

  log('✓ Passo 1 concluído');
}

// ---------------------------------------------------------------------------
// Passo 2: UPSERT dados de Dev em Prod (Passo 2.2 + 2.3)
// Ordem: root-first para respeitar FKs
//
// Parceiro dev: BIP Brasil
//   institution_id:       00d8859d-e0ab-4b5b-8b9d-4e108f2f0610
//   partner_opportunities: 8cb2f939-1875-497e-a43a-83371ae4f0c2
//
// FKs importantes:
//   partner_steps.partner_id    → partner_opportunities.id
//   partner_forms.partner_id    → partner_opportunities.id
//   partner_forms.step_id       → partner_steps.id
//   knowledge_documents.category_id → knowledge_categories.id
//   knowledge_documents.partner_id  = NULL (sem FK ativa nos docs de dev)
//   knowledge_document_versions.document_id → knowledge_documents.id
//   knowledge_keywords.document_id  → knowledge_documents.id
// ---------------------------------------------------------------------------

async function step2_upsert(dev: SupabaseClient, prod: SupabaseClient) {
  log('\n=== PASSO 2: UPSERT dados de Dev ===');

  // --- Dados educacionais MEC (root → leaf) ---

  await upsertTable(dev, prod, 'institutions', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'campus', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'courses', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'institutions_info_emec', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'institutions_info_sisu', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'programs', { orderBy: 'created_at' });

  // --- Parceiro BIP Brasil (dev) ---
  // institution (00d8859d) já upsertada acima

  await upsertTable(dev, prod, 'partner_institutions', {
    orderBy: 'institution_id',
    onConflict: 'institution_id',
  });

  await upsertTable(dev, prod, 'partner_opportunities', { orderBy: 'created_at' });

  // partner_steps: FK → partner_opportunities (deve existir em prod agora)
  await upsertTable(dev, prod, 'partner_steps', { orderBy: 'sort_order' });

  // partner_forms: FK → partner_opportunities + partner_steps
  await upsertTable(dev, prod, 'partner_forms', { orderBy: 'sort_order' });

  // --- Dados educacionais dependentes de courses ---

  await upsertTable(dev, prod, 'opportunities', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'opportunities_sisu_vacancies', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'courses_prouni_vacancies', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'important_dates', { orderBy: 'created_at' });

  // --- Knowledge base (Cloudinha) ---
  // Ordem: categories → documents → versions + keywords

  await upsertTable(dev, prod, 'knowledge_categories', { orderBy: 'created_at' });

  // knowledge_documents: partner_id = NULL em dev (sem FK ativa a resolver)
  await upsertTable(dev, prod, 'knowledge_documents', { orderBy: 'created_at' });

  await upsertTable(dev, prod, 'knowledge_document_versions', {
    orderBy: 'created_at',
  });

  await upsertTable(dev, prod, 'knowledge_keywords', { orderBy: 'created_at' });

  // --- Tabelas de config da plataforma ---

  await upsertTable(dev, prod, 'cloudinha_starters', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'home_sections', { orderBy: 'created_at' });
  await upsertTable(dev, prod, 'match_config', {
    orderBy: 'weight_key',
    onConflict: 'weight_key',
  });
  await upsertTable(dev, prod, 'agent_prompts', {
    orderBy: 'agent_key',
    onConflict: 'agent_key',
  });
  await upsertTable(dev, prod, 'course_groups', {
    orderBy: 'group_key',
    onConflict: 'group_key',
  });
  await upsertTable(dev, prod, 'system_intents', { orderBy: 'created_at' });

  log('✓ Passo 2 concluído');
}

// ---------------------------------------------------------------------------
// Passo 3: Mapear partners legados de Prod para partner_institutions (Passo 2.3)
//
// Os 6 parceiros legados (Insper, Fundação Estudar, etc.) existem na tabela
// `partners` de prod com schema antigo. Criamos pares em `institutions` +
// `partner_institutions` + `partner_opportunities` para que apareçam no app.
//
// Não confundir com o BIP Brasil que vem do dev via step2 acima.
// ---------------------------------------------------------------------------

async function step3_mapLegacyPartners(prod: SupabaseClient) {
  log('\n=== PASSO 3: Mapear partners legados → partner_institutions ===');

  const { data: partners, error } = await prod
    .from('partners')
    .select('id, name, description, location, link, coverimage, external_redirect_config');

  if (error) throw new Error(`Erro ao ler partners: ${error.message}`);
  if (!partners || partners.length === 0) {
    log('  ⚠ Nenhum partner legado encontrado — pulando passo 3');
    return;
  }

  log(`  Encontrados ${partners.length} partners legados`);

  for (const partner of partners as Record<string, unknown>[]) {
    const partnerName = partner.name as string;
    log(`  Processando: ${partnerName}`);

    // Pular se já migrado (por nome, evitar duplicata)
    const { data: existing } = await prod
      .from('institutions')
      .select('id')
      .eq('name', partnerName)
      .eq('is_partner', true)
      .maybeSingle();

    let institutionId: string;

    if (existing) {
      institutionId = existing.id as string;
      log(`    → institution já existe: ${institutionId}`);
    } else {
      const { data: newInst, error: instError } = await prod
        .from('institutions')
        .insert({ name: partnerName, is_partner: true })
        .select('id')
        .single();
      if (instError) throw new Error(`Erro ao criar institution para "${partnerName}": ${instError.message}`);
      institutionId = newInst.id as string;
      log(`    → institution criada: ${institutionId}`);
    }

    const { data: existingPI } = await prod
      .from('partner_institutions')
      .select('institution_id')
      .eq('institution_id', institutionId)
      .maybeSingle();

    if (!existingPI) {
      const { error: piError } = await prod
        .from('partner_institutions')
        .insert({
          institution_id: institutionId,
          description: partner.description,
          location: partner.location,
          logo_url: null,
          cover_url: partner.coverimage,
          website_url: partner.link,
          brand_color: null,
        });
      if (piError) throw new Error(`Erro ao criar partner_institutions para "${partnerName}": ${piError.message}`);
      log(`    → partner_institutions criado`);
    } else {
      log(`    → partner_institutions já existe`);
    }

    const { data: existingPO } = await prod
      .from('partner_opportunities')
      .select('id')
      .eq('institution_id', institutionId)
      .maybeSingle();

    if (!existingPO) {
      const { error: poError } = await prod
        .from('partner_opportunities')
        .insert({
          institution_id: institutionId,
          name: partnerName,
          description: partner.description,
          opportunity_type: 'scholarship',
          eligibility_criteria: {},
          external_redirect_config: partner.external_redirect_config ?? {},
          status: 'inactive',
        });
      if (poError) throw new Error(`Erro ao criar partner_opportunities para "${partnerName}": ${poError.message}`);
      log(`    → partner_opportunities criado (status=inactive)`);
    } else {
      log(`    → partner_opportunities já existe`);
    }
  }

  log('✓ Passo 3 concluído');
}

// ---------------------------------------------------------------------------
// Passo 4: REFRESH da Materialized View
// ---------------------------------------------------------------------------

async function step4_refreshMatview(prod: SupabaseClient) {
  log('\n=== PASSO 4: REFRESH MATERIALIZED VIEW v_unified_opportunities ===');

  const { error } = await prod.rpc('refresh_unified_opportunities');

  if (error) {
    log(`  ⚠ RPC refresh_unified_opportunities não disponível: ${error.message}`);
    log('  → AÇÃO MANUAL: Executar no SQL Editor do Supabase (prod):');
    log('    REFRESH MATERIALIZED VIEW v_unified_opportunities;');
    log('    REFRESH MATERIALIZED VIEW mv_course_catalog;  -- se existir');
  } else {
    log('  ✓ REFRESH executado via RPC');
  }

  log('✓ Passo 4 concluído');
}

// ---------------------------------------------------------------------------
// Passo 5: Validação final (Card 3)
// ---------------------------------------------------------------------------

async function step5_validate(prod: SupabaseClient) {
  log('\n=== PASSO 5: VALIDAÇÃO DE CONTAGENS ===');

  const checks: Array<{ table: string; expected: number; op: '==' | '>=' }> = [
    // Dados de usuário — PRESERVADOS
    { table: 'user_profiles',             expected: 3058,  op: '==' },
    { table: 'user_enem_scores',          expected: 606,   op: '==' },
    { table: 'user_preferences',          expected: 1270,  op: '==' },
    { table: 'user_income',               expected: 466,   op: '==' },
    { table: 'chat_messages',             expected: 42394, op: '==' },
    // Dados de parceiros legados — PRESERVADOS
    { table: 'partners',                  expected: 6,     op: '==' },
    { table: 'partner_forms',             expected: 233,   op: '>=' }, // 233 legados + 11 dev
    { table: 'student_applications',      expected: 430,   op: '==' },
    { table: 'knowledge_documents',       expected: 10,    op: '>=' }, // 5 prod + 10 dev (upsert)
    // Parceiro BIP Brasil (de dev)
    { table: 'partner_institutions',      expected: 1,     op: '>=' },
    { table: 'partner_opportunities',     expected: 1,     op: '>=' },
    { table: 'partner_steps',             expected: 1,     op: '>=' },
    { table: 'knowledge_categories',      expected: 6,     op: '>=' },
    { table: 'knowledge_document_versions', expected: 17,  op: '>=' },
    { table: 'knowledge_keywords',        expected: 54,    op: '>=' },
    // Dados educacionais (de dev)
    { table: 'institutions',              expected: 138,   op: '>=' },
    { table: 'courses',                   expected: 7539,  op: '>=' },
    { table: 'opportunities',             expected: 66289, op: '>=' },
    // Zerados intencionalmente
    { table: 'user_favorites',            expected: 0,     op: '==' },
  ];

  let passed = 0;
  let failed = 0;

  for (const check of checks) {
    try {
      const count = await countProd(prod, check.table);
      const ok = check.op === '>=' ? count >= check.expected : count === check.expected;
      const icon = ok ? '✅' : '❌';
      const opStr = check.op === '>=' ? `>= ${check.expected}` : `== ${check.expected}`;
      log(`  ${icon} ${check.table}: ${count} (esperado: ${opStr})`);
      if (ok) passed++; else failed++;
    } catch (e) {
      log(`  ⚠ ${check.table}: erro — ${(e as Error).message}`);
      failed++;
    }
  }

  log(`\n=== RESULTADO: ${passed} ✅ | ${failed} ❌ ===`);

  if (failed > 0) {
    throw new Error(`${failed} validação(ões) falharam. Verificar antes de prosseguir.`);
  }

  log('✓ Passo 5 concluído — todos os checks passaram');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log('🚀 Iniciando migração Dev → Prod');
  log('⚠️  PRÉ-REQUISITO: Backup de Prod já feito.');
  log('⚠️  PRÉ-REQUISITO: supabase db push (Card 1) já executado.');
  log('');

  assertEnv();

  const dev = createClient(DEV_URL, DEV_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const prod = createClient(PROD_URL, PROD_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    await step1_truncate(prod);
    await step2_upsert(dev, prod);
    await step3_mapLegacyPartners(prod);
    await step4_refreshMatview(prod);
    await step5_validate(prod);

    log('\n🎉 Migração concluída com sucesso!');
    log('Próximo: Card 4 — Deploy Vercel + DNS');
    log('⚠️  Lembrete: ativar manualmente os partner_opportunities dos parceiros legados no admin (/partner-opportunities).');
  } catch (err) {
    log(`\n💥 ERRO FATAL: ${(err as Error).message}`);
    log('Migração interrompida. Verificar estado do banco antes de re-executar.');
    process.exit(1);
  }
}

main();

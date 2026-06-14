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

const PAGE_SIZE = 500; // registros por batch

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

async function truncateProd(prod: SupabaseClient, table: string) {
  log(`  TRUNCATE ${table}...`);
  const { error } = await prod.rpc('execute_readonly_query', {
    query: `TRUNCATE TABLE ${table} CASCADE`
  });
  // execute_readonly_query é somente leitura — usar SQL direto via from workaround
  // Como não temos RPC de escrita, usar delete all via SDK:
  if (error) {
    // Fallback: delete sem filtro (equivalente a TRUNCATE para propósitos práticos)
    const { error: e2 } = await prod.from(table).delete().neq('id', '00000000-0000-0000-0000-000000000000');
    if (e2) throw new Error(`Falha ao truncar ${table}: ${e2.message}`);
  }
  log(`  ✓ ${table} truncado`);
}

async function migrateTable(
  dev: SupabaseClient,
  prod: SupabaseClient,
  table: string,
  options: {
    orderBy?: string;
    select?: string;
    transform?: (rows: Record<string, unknown>[]) => Record<string, unknown>[];
  } = {}
) {
  const { orderBy = 'created_at', select = '*', transform } = options;
  log(`  Migrando ${table}...`);

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

    const { error: insertError } = await prod
      .from(table)
      .upsert(rows as Record<string, unknown>[], { onConflict: 'id' });

    if (insertError) throw new Error(`Erro ao inserir em ${table} (página ${page}): ${insertError.message}`);

    total += rows.length;
    log(`    → ${total} registros inseridos em ${table}...`);

    if (data.length < PAGE_SIZE) break;
    page++;
  }

  log(`  ✓ ${table}: ${total} registros migrados`);
  return total;
}

async function countProd(prod: SupabaseClient, table: string): Promise<number> {
  const { count, error } = await prod.from(table).select('*', { count: 'exact', head: true });
  if (error) throw new Error(`Erro ao contar ${table}: ${error.message}`);
  return count ?? 0;
}

// ---------------------------------------------------------------------------
// Passo 1: TRUNCATE tabelas educacionais em Prod (Card 2, Passo 2.1)
// Ordem: leaf-first para respeitar integridade referencial
// NÃO truncar: partners, partner_forms, partner_steps, student_applications,
//              knowledge_documents, partners_click, partners_users, partner_solicitations
// ---------------------------------------------------------------------------

async function step1_truncate(prod: SupabaseClient) {
  log('\n=== PASSO 1: TRUNCATE (tabelas educacionais) ===');

  const toTruncate = [
    // Transacionais com FK para courses/opportunities
    'user_favorites',
    'external_redirect_clicks',
    'passport_applications',
    // Educacionais — leaf-first
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

  for (const table of toTruncate) {
    try {
      await truncateProd(prod, table);
    } catch (e) {
      // Tabelas legadas podem não existir em prod pós-push
      log(`  ⚠ Ignorando ${table}: ${(e as Error).message}`);
    }
  }

  log('✓ Passo 1 concluído');
}

// ---------------------------------------------------------------------------
// Passo 2: INSERT dados de Dev em Prod (Card 2, Passo 2.2)
// Ordem: root-first para respeitar FKs
// ---------------------------------------------------------------------------

async function step2_insert(dev: SupabaseClient, prod: SupabaseClient) {
  log('\n=== PASSO 2: INSERT dados de Dev ===');

  // 1. institutions (138)
  await migrateTable(dev, prod, 'institutions', { orderBy: 'created_at' });

  // 2. campus (1.231) — depende de institutions
  await migrateTable(dev, prod, 'campus', { orderBy: 'created_at' });

  // 3. courses (7.539) — depende de campus
  await migrateTable(dev, prod, 'courses', { orderBy: 'created_at' });

  // 4. institutions_info_emec — depende de institutions
  await migrateTable(dev, prod, 'institutions_info_emec', { orderBy: 'created_at' });

  // 5. institutions_info_sisu — depende de institutions
  await migrateTable(dev, prod, 'institutions_info_sisu', { orderBy: 'created_at' });

  // 6. programs (6)
  await migrateTable(dev, prod, 'programs', { orderBy: 'created_at' });

  // 7. partner_institutions (1) — depende de institutions
  await migrateTable(dev, prod, 'partner_institutions', { orderBy: 'institution_id' });

  // 8. opportunities (66.289) — depende de courses
  await migrateTable(dev, prod, 'opportunities', { orderBy: 'created_at' });

  // 9. opportunities_sisu_vacancies — depende de opportunities
  await migrateTable(dev, prod, 'opportunities_sisu_vacancies', { orderBy: 'created_at' });

  // 10. courses_prouni_vacancies — depende de courses
  await migrateTable(dev, prod, 'courses_prouni_vacancies', { orderBy: 'created_at' });

  // 11. partner_opportunities (1) — depende de partner_institutions
  await migrateTable(dev, prod, 'partner_opportunities', { orderBy: 'created_at' });

  // 12. important_dates (3)
  await migrateTable(dev, prod, 'important_dates', { orderBy: 'created_at' });

  // 13. Tabelas de config
  await migrateTable(dev, prod, 'cloudinha_starters', { orderBy: 'created_at' });
  await migrateTable(dev, prod, 'home_sections', { orderBy: 'created_at' });
  await migrateTable(dev, prod, 'match_config', { orderBy: 'created_at' });
  await migrateTable(dev, prod, 'agent_prompts', { orderBy: 'updated_at' });
  await migrateTable(dev, prod, 'course_groups', { orderBy: 'group_key' });
  await migrateTable(dev, prod, 'system_intents', { orderBy: 'created_at' });

  log('✓ Passo 2 concluído');
}

// ---------------------------------------------------------------------------
// Passo 3: Mapear partners legados de Prod para partner_institutions (Passo 2.3)
//
// Schema legacy partners (prod):
//   id, name, description, location, type, income, dates, link,
//   coverimage, applications_open, external_redirect_config
//
// Schema partner_institutions (dev/prod novo):
//   institution_id (FK → institutions), logo_url, cover_url,
//   description, brand_color, location, website_url
//
// Estratégia:
//   1. Para cada partner legado, criar uma institution em prod com is_partner=true
//   2. Criar o partner_institutions correspondente referenciando a nova institution
//   3. Criar um partner_opportunities básico com status='inactive' para ativar depois
// ---------------------------------------------------------------------------

async function step3_mapPartners(prod: SupabaseClient) {
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

    // Verificar se já existe institution com este nome (evitar duplicata)
    const { data: existing } = await prod
      .from('institutions')
      .select('id')
      .eq('name', partnerName)
      .eq('is_partner', true)
      .maybeSingle();

    let institutionId: string;

    if (existing) {
      institutionId = existing.id as string;
      log(`    → Reutilizando institution existente: ${institutionId}`);
    } else {
      // Criar nova institution para o parceiro
      const { data: newInst, error: instError } = await prod
        .from('institutions')
        .insert({ name: partnerName, is_partner: true })
        .select('id')
        .single();

      if (instError) throw new Error(`Erro ao criar institution para "${partnerName}": ${instError.message}`);
      institutionId = newInst.id as string;
      log(`    → Institution criada: ${institutionId}`);
    }

    // Verificar se já existe partner_institutions para esta institution
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
          logo_url: null,           // partners legados usam coverimage, não logo separado
          cover_url: partner.coverimage,
          website_url: partner.link,
          brand_color: null,
        });

      if (piError) throw new Error(`Erro ao criar partner_institutions para "${partnerName}": ${piError.message}`);
      log(`    → partner_institutions criado`);
    } else {
      log(`    → partner_institutions já existe, pulando`);
    }

    // Criar partner_opportunities básico se não existir
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
          status: 'inactive', // Reativar manualmente após validação
        });

      if (poError) throw new Error(`Erro ao criar partner_opportunities para "${partnerName}": ${poError.message}`);
      log(`    → partner_opportunities criado (status=inactive)`);
    } else {
      log(`    → partner_opportunities já existe, pulando`);
    }
  }

  log('✓ Passo 3 concluído');
}

// ---------------------------------------------------------------------------
// Passo 4: REFRESH da Materialized View (Card 2, Passo 2.4)
// ---------------------------------------------------------------------------

async function step4_refreshMatview(prod: SupabaseClient) {
  log('\n=== PASSO 4: REFRESH MATERIALIZED VIEW v_unified_opportunities ===');

  // Chamar via RPC execute_readonly_query não funciona para REFRESH (é write).
  // Usar a função existente refresh_unified_opportunities se disponível,
  // caso contrário instruir o usuário.
  const { error } = await prod.rpc('refresh_unified_opportunities');

  if (error) {
    log(`  ⚠ RPC refresh_unified_opportunities não disponível: ${error.message}`);
    log('  → AÇÃO MANUAL NECESSÁRIA: Executar no SQL Editor do Supabase (prod):');
    log('    REFRESH MATERIALIZED VIEW v_unified_opportunities;');
    log('  → Também verificar se existe mv_course_catalog:');
    log('    REFRESH MATERIALIZED VIEW mv_course_catalog;');
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

  const checks: Array<{ table: string; expected: number; op: '==' | '>=' | '==' }> = [
    // Dados de usuário — PRESERVADOS
    { table: 'user_profiles',      expected: 3058,  op: '==' },
    { table: 'user_enem_scores',   expected: 606,   op: '==' },
    { table: 'user_preferences',   expected: 1270,  op: '==' },
    { table: 'user_income',        expected: 466,   op: '==' },
    { table: 'chat_messages',      expected: 42394, op: '==' },
    // Dados de parceiros — PRESERVADOS
    { table: 'partners',           expected: 6,     op: '==' },
    { table: 'partner_forms',      expected: 233,   op: '==' },
    { table: 'student_applications', expected: 430, op: '==' },
    { table: 'knowledge_documents', expected: 5,    op: '==' },
    // Dados educacionais (de dev) — MIGRADOS
    { table: 'institutions',       expected: 138,   op: '>=' },
    { table: 'courses',            expected: 7539,  op: '>=' },
    { table: 'opportunities',      expected: 66289, op: '>=' },
    // Novas tabelas de parceiros
    { table: 'partner_institutions', expected: 1,   op: '>=' },
    // Tabelas zeradas intencionalmente
    { table: 'user_favorites',     expected: 0,     op: '==' },
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
      log(`  ⚠ ${check.table}: erro ao contar — ${(e as Error).message}`);
      failed++;
    }
  }

  log(`\n=== RESULTADO: ${passed} ✅ | ${failed} ❌ ===`);

  if (failed > 0) {
    throw new Error(`${failed} validação(ões) falharam. Verificar manualmente antes de prosseguir.`);
  }

  log('✓ Passo 5 concluído — todos os checks passaram');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log('🚀 Iniciando migração Dev → Prod');
  log('⚠️  PRÉ-REQUISITO: Confirme que o backup de Prod já foi feito antes de continuar.');
  log('⚠️  PRÉ-REQUISITO: Confirme que o supabase db push (Card 1) já foi executado.');
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
    await step2_insert(dev, prod);
    await step3_mapPartners(prod);
    await step4_refreshMatview(prod);
    await step5_validate(prod);

    log('\n🎉 Migração concluída com sucesso!');
    log('Próximo passo: Card 4 — Deploy Vercel + DNS');
  } catch (err) {
    log(`\n💥 ERRO FATAL: ${(err as Error).message}`);
    log('A migração foi interrompida. Verificar estado do banco antes de re-executar.');
    process.exit(1);
  }
}

main();

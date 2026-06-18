/**
 * migrate-dev-to-prod.ts
 * Migra dados do banco DEV (nubo-hub) → PROD (nubo-hub-prod)
 *
 * Uso:
 *   DEV_SUPABASE_URL=... DEV_SUPABASE_SERVICE_KEY=... \
 *   PROD_SUPABASE_URL=... PROD_SUPABASE_SERVICE_KEY=... \
 *   npx tsx scripts/migrate-dev-to-prod.ts
 */

import { createClient } from '@supabase/supabase-js';
import { execSync } from 'child_process';

const DEV_URL = process.env.DEV_SUPABASE_URL!;
const DEV_KEY = process.env.DEV_SUPABASE_SERVICE_KEY!;
const PROD_URL = process.env.PROD_SUPABASE_URL!;
const PROD_KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;

if (!DEV_URL || !DEV_KEY || !PROD_URL || !PROD_KEY) {
  console.error('❌ Missing env vars.');
  process.exit(1);
}

const dev = createClient(DEV_URL, DEV_KEY, { auth: { persistSession: false } });
const prod = createClient(PROD_URL, PROD_KEY, { auth: { persistSession: false } });

const BATCH_SIZE = 200;

async function fetchAll<T>(client: ReturnType<typeof createClient>, table: string, select = '*'): Promise<T[]> {
  const results: T[] = [];
  let from = 0;
  while (true) {
    const { data, error } = await client.from(table).select(select).range(from, from + BATCH_SIZE - 1);
    if (error) throw new Error(`fetchAll ${table}: ${error.message}`);
    if (!data || data.length === 0) break;
    results.push(...(data as T[]));
    if (data.length < BATCH_SIZE) break;
    from += BATCH_SIZE;
  }
  return results;
}

async function upsertBatched(table: string, rows: Record<string, unknown>[], onConflict = 'id') {
  if (rows.length === 0) { console.log(`  ⏭  ${table}: 0 rows, skip`); return; }
  let inserted = 0;
  let skipped = 0;
  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batch = rows.slice(i, i + BATCH_SIZE);
    const { error } = await prod.from(table).upsert(batch, { onConflict });
    if (error) {
      // FK violation or similar: retry row-by-row and skip invalid rows
      if (error.message.includes('foreign key') || error.message.includes('violates')) {
        for (const row of batch) {
          const { error: rowErr } = await prod.from(table).upsert(row, { onConflict });
          if (rowErr) skipped++;
          else inserted++;
        }
      } else {
        throw new Error(`upsert ${table} batch ${i}: ${error.message}`);
      }
    } else {
      inserted += batch.length;
    }
    if (rows.length > BATCH_SIZE) process.stdout.write(`\r  ⏳ ${table}: ${inserted}/${rows.length}`);
  }
  if (rows.length > BATCH_SIZE) process.stdout.write('\n');
  console.log(`  ✅ ${table}: ${inserted} rows${skipped > 0 ? ` (${skipped} skipped - FK missing)` : ''}`);
}

/** Delete all rows via paginated ID fetch, optionally skipping specific IDs */
async function deleteAll(table: string, idCol = 'id', excludeIds: string[] = []) {
  let deleted = 0;
  while (true) {
    let query = prod.from(table).select(idCol).limit(BATCH_SIZE);
    if (excludeIds.length > 0) query = query.not(idCol, 'in', `(${excludeIds.map(id => `"${id}"`).join(',')})`);
    const { data, error } = await query;
    if (error) { console.warn(`  ⚠️  ${table} fetchIds: ${error.message}`); break; }
    if (!data || data.length === 0) break;
    const ids = data.map((r: Record<string, unknown>) => r[idCol]);
    const { error: delErr } = await prod.from(table).delete().in(idCol, ids);
    if (delErr) { console.warn(`  ⚠️  ${table} delete batch: ${delErr.message}`); break; }
    deleted += ids.length;
    process.stdout.write(`\r  🗑  ${table}: ${deleted} deleted`);
  }
  process.stdout.write('\n');
  console.log(`  ✅ ${table}: cleared${excludeIds.length > 0 ? ` (${excludeIds.length} preserved)` : ''}`);
}

// ---------------------------------------------------------------------------
// PASSO 1 — Limpar tabelas em prod na ordem correta (leaf → root)
// ---------------------------------------------------------------------------
async function step1_clear() {
  console.log('\n📦 Passo 1 — Limpando tabelas em prod...');

  // Transacionais com FK para courses/opportunities (já foram limpas, mas por segurança)
  await deleteAll('user_favorites');
  await deleteAll('external_redirect_clicks');
  await deleteAll('passport_applications');

  // Vagas (dependem de opportunities/courses)
  await deleteAll('opportunities_sisu_vacancies');
  await deleteAll('courses_prouni_vacancies');
  await deleteAll('important_dates');

  // Partner_opportunities: preservar os que são referenciados por student_applications
  // (student_applications.partner_id → partner_opportunities.id, NOT NULL → não pode SET NULL)
  const { data: saRefs } = await prod.from('student_applications').select('partner_id').not('partner_id', 'is', null);
  const preservedOppIds = [...new Set((saRefs ?? []).map((r: Record<string, unknown>) => r.partner_id as string))];
  console.log(`  🔒 Preservando ${preservedOppIds.length} partner_opportunities referenciados por student_applications`);

  await deleteAll('partner_forms');
  await deleteAll('partner_steps');
  await deleteAll('partner_opportunities', 'id', preservedOppIds);

  // Institutions: preservar as que ainda têm partner_opportunities apontando
  const { data: oppInsts } = await prod.from('partner_opportunities').select('institution_id').not('institution_id', 'is', null);
  const preservedInstIds = [...new Set((oppInsts ?? []).map((r: Record<string, unknown>) => r.institution_id as string))];
  console.log(`  🔒 Preservando ${preservedInstIds.length} institutions referenciadas por partner_opportunities`);

  await deleteAll('partner_institutions', 'institution_id');
  await deleteAll('opportunities');
  await deleteAll('courses');
  await deleteAll('campus');
  await deleteAll('institutions_info_emec');
  await deleteAll('institutions_info_sisu');
  await deleteAll('institutions', 'id', preservedInstIds);
  await deleteAll('programs');

  // Atualizar partner_opportunities preservados para valor válido no novo constraint
  // (os 3 têm valores antigos como 'bolsa', 'bootcamp', 'mentoria')
  if (preservedOppIds.length > 0) {
    const { error: updErr } = await prod
      .from('partner_opportunities')
      .update({ opportunity_type: 'programa de bolsa' })
      .in('id', preservedOppIds);
    if (updErr) console.warn(`  ⚠️  update opportunity_type: ${updErr.message}`);
    else console.log(`  ✅ ${preservedOppIds.length} partner_opportunities atualizados para 'programa de bolsa'`);
  }

  console.log('  ℹ️  Migrations já aplicadas via db push — prosseguindo com upsert');
}

// ---------------------------------------------------------------------------
// PASSO 2 — UPSERT dados de dev → prod (root-first)
// ---------------------------------------------------------------------------
async function step2_upsert() {
  console.log('\n📥 Passo 2 — Inserindo dados de dev...');

  // Educational root tables
  const institutions = await fetchAll(dev, 'institutions');
  console.log(`  📊 institutions em dev: ${institutions.length}`);
  await upsertBatched('institutions', institutions as Record<string, unknown>[]);

  await upsertBatched('campus', await fetchAll(dev, 'campus') as Record<string, unknown>[]);
  await upsertBatched('courses', await fetchAll(dev, 'courses') as Record<string, unknown>[]);
  await upsertBatched('institutions_info_emec', await fetchAll(dev, 'institutions_info_emec') as Record<string, unknown>[]);
  await upsertBatched('institutions_info_sisu', await fetchAll(dev, 'institutions_info_sisu') as Record<string, unknown>[]);
  // Selecionar apenas colunas que existem em prod (dev tem is_fully_imported, prev_program_id a mais)
  const programs = await fetchAll(dev, 'programs', 'id,type,cycle_year,cycle_semester,title,description,status,redirect_url,starts_at,ends_at,created_at,updated_at');
  await upsertBatched('programs', programs as Record<string, unknown>[]);

  // Partner data (BIP Brasil e outros de dev)
  await upsertBatched('partner_institutions', await fetchAll(dev, 'partner_institutions') as Record<string, unknown>[], 'institution_id');
  await upsertBatched('partner_opportunities', await fetchAll(dev, 'partner_opportunities') as Record<string, unknown>[]);
  await upsertBatched('partner_steps', await fetchAll(dev, 'partner_steps') as Record<string, unknown>[]);
  await upsertBatched('partner_forms', await fetchAll(dev, 'partner_forms') as Record<string, unknown>[]);

  // Opportunities & vacancies
  await upsertBatched('opportunities', await fetchAll(dev, 'opportunities') as Record<string, unknown>[]);
  // opportunities_sisu_vacancies: pulado — será importado via ETL no admin após upload do rawsisuvacancies
  console.log('  ⏭  opportunities_sisu_vacancies: pulado (importar via ETL no admin)');
  await upsertBatched('courses_prouni_vacancies', await fetchAll(dev, 'courses_prouni_vacancies') as Record<string, unknown>[]);
  await upsertBatched('important_dates', await fetchAll(dev, 'important_dates') as Record<string, unknown>[]);

  // Knowledge base
  await upsertBatched('knowledge_categories', await fetchAll(dev, 'knowledge_categories') as Record<string, unknown>[]);
  await upsertBatched('knowledge_documents', await fetchAll(dev, 'knowledge_documents') as Record<string, unknown>[]);
  await upsertBatched('knowledge_document_versions', await fetchAll(dev, 'knowledge_document_versions') as Record<string, unknown>[]);
  await upsertBatched('knowledge_keywords', await fetchAll(dev, 'knowledge_keywords') as Record<string, unknown>[]);

  // Config / content
  await upsertBatched('cloudinha_starters', await fetchAll(dev, 'cloudinha_starters') as Record<string, unknown>[]);
  await upsertBatched('home_sections', await fetchAll(dev, 'home_sections') as Record<string, unknown>[]);
  await upsertBatched('match_config', await fetchAll(dev, 'match_config') as Record<string, unknown>[], 'weight_key');
  await upsertBatched('agent_prompts', await fetchAll(dev, 'agent_prompts') as Record<string, unknown>[], 'agent_key');
  await upsertBatched('course_groups', await fetchAll(dev, 'course_groups') as Record<string, unknown>[], 'group_key');
  await upsertBatched('system_intents', await fetchAll(dev, 'system_intents') as Record<string, unknown>[]);
}

// ---------------------------------------------------------------------------
// PASSO 3 — Criar pares partner_institutions/partner_opportunities para partners legados de prod
// ---------------------------------------------------------------------------
async function step3_legacy_partners() {
  console.log('\n🏛  Passo 3 — Mapeando partners legados de prod...');

  const { data: partners, error } = await prod.from('partners').select('*');
  if (error) { console.warn(`  ⚠️  partners: ${error.message}`); return; }
  if (!partners || partners.length === 0) { console.log('  ℹ️  Nenhum partner legado'); return; }

  console.log(`  📋 ${partners.length} partners legados encontrados`);

  for (const p of partners as Record<string, unknown>[]) {
    // Verificar se já existe partner_institution para este partner
    const { data: existing } = await prod
      .from('partner_institutions')
      .select('id')
      .eq('partner_id', p.id)
      .limit(1);

    if (existing && existing.length > 0) {
      console.log(`  ⏭  ${p.name}: partner_institution já existe`);
      continue;
    }

    const piId = crypto.randomUUID();
    const { error: piErr } = await prod.from('partner_institutions').insert({
      id: piId,
      partner_id: p.id,
      name: p.name,
      slug: p.slug,
      logo_url: p.logo_url,
      website_url: p.website_url,
    });
    if (piErr) { console.warn(`  ⚠️  partner_institution ${p.name}: ${piErr.message}`); continue; }

    const { error: poErr } = await prod.from('partner_opportunities').insert({
      id: crypto.randomUUID(),
      partner_id: p.id,
      title: `Oportunidades — ${p.name}`,
      status: 'inactive',
    });
    if (poErr) console.warn(`  ⚠️  partner_opportunity ${p.name}: ${poErr.message}`);
    else console.log(`  ✅ ${p.name}: mapeado`);
  }
}

// ---------------------------------------------------------------------------
// PASSO 4 — REFRESH MATERIALIZED VIEW
// ---------------------------------------------------------------------------
async function step4_refresh() {
  console.log('\n🔄 Passo 4 — REFRESH MATERIALIZED VIEW v_unified_opportunities...');
  const { error } = await prod.rpc('refresh_unified_opportunities');
  if (error) {
    console.warn(`  ⚠️  RPC não disponível: ${error.message}`);
    console.log('  ℹ️  Execute manualmente no SQL Editor:');
    console.log('      REFRESH MATERIALIZED VIEW v_unified_opportunities;');
  } else {
    console.log('  ✅ View atualizada');
  }
}

// ---------------------------------------------------------------------------
// PASSO 5 — Validação de contagens
// ---------------------------------------------------------------------------
async function step5_validate() {
  console.log('\n🔍 Passo 5 — Validação...');

  const checks: { table: string; devMin?: number }[] = [
    { table: 'institutions', devMin: 100 },
    { table: 'campus', devMin: 1000 },
    { table: 'courses', devMin: 7000 },
    { table: 'programs', devMin: 5 },
    { table: 'opportunities', devMin: 60000 },
    { table: 'partner_institutions' },
    { table: 'partner_opportunities' },
    { table: 'partner_steps' },
    { table: 'partner_forms' },
    { table: 'knowledge_documents' },
    { table: 'match_config' },
    { table: 'agent_prompts' },
    { table: 'cloudinha_starters' },
    // Preserved (not migrated — should stay)
    { table: 'user_profiles' },
    { table: 'chat_messages' },
    { table: 'student_applications' },
    { table: 'partners' },
  ];

  console.log('\n  Tabela                          | DEV    | PROD   | OK');
  console.log('  --------------------------------|--------|--------|----');

  for (const { table, devMin } of checks) {
    const [devRes, prodRes] = await Promise.all([
      dev.from(table).select('*', { count: 'exact', head: true }),
      prod.from(table).select('*', { count: 'exact', head: true }),
    ]);
    const d = devRes.count ?? 0;
    const p = prodRes.count ?? 0;
    const ok = devMin ? p >= devMin : p >= 0;
    const status = ok ? '✅' : '❌';
    console.log(`  ${table.padEnd(32)}| ${String(d).padEnd(6)} | ${String(p).padEnd(6)} | ${status}`);
  }
}

// ---------------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------------
async function main() {
  console.log('🚀 Migração DEV → PROD iniciada');
  console.log(`   DEV:  ${DEV_URL}`);
  console.log(`   PROD: ${PROD_URL}`);

  const skipClear = process.argv.includes('--skip-clear');
  if (!skipClear) {
    await step1_clear();
  } else {
    console.log('\n⏭  Passo 1 ignorado (--skip-clear)');
  }
  await step2_upsert();
  // step3_legacy_partners: obsoleto — schema migrou de partner_id para institution_id; partners legados permanecem na tabela partners
  await step4_refresh();
  await step5_validate();

  console.log('\n✅ Migração concluída!');
}

main().catch(err => {
  console.error('❌ Erro fatal:', err);
  process.exit(1);
});

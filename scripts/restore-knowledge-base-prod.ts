/**
 * restore-knowledge-base-prod.ts
 * Restaura metadados da base de conhecimento no PROD (knowledge_documents +
 * knowledge_document_versions + knowledge_keywords), apontando para os arquivos
 * que JÁ existem no bucket `knowledge-base` do prod.
 *
 * Contexto: a migração da ADR-0021 não repovoou essas linhas (skip de FK em
 * category_id). NÃO mexe na tabela `documents`/`match_documents` (legado morto).
 *
 * Idempotente: pula qualquer doc cujo `storage_path` já exista em prod.
 * Usa SERVICE ROLE KEY (bypassa RLS) — a anon key não escreve nessas tabelas.
 *
 * Uso:
 *   PROD_SUPABASE_URL=... PROD_SUPABASE_SERVICE_KEY=... \
 *   npx tsx scripts/restore-knowledge-base-prod.ts
 */

import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;

if (!URL || !KEY) {
  console.error('❌ Faltam env vars: PROD_SUPABASE_URL e PROD_SUPABASE_SERVICE_KEY');
  process.exit(1);
}

const db = createClient(URL, KEY, { auth: { persistSession: false } });

// Categorias do PROD (UUIDs do prod — diferentes do dev; remap por nome)
const CAT = {
  cloudinha: '60fd1fe4-faec-49da-a277-dadd0b9843b0',
  general: '91b6c7c5-1fa3-4468-92f3-79293fefaa79',
  partner: '7691ff13-32a7-47cf-938a-bf6fa49ea205',
  passport: '76c4b1d0-80f8-480b-bddc-0ec86af46a59',
  prouni: 'cc13f0de-fddc-4268-8706-67ce53701707',
  sisu: '069d2144-8e8f-4951-a271-0820f6b4f875',
} as const;

interface DocSeed {
  title: string;
  description: string | null;
  category_id: string;
  storage_path: string;
  is_active: boolean;
  keywords: string[];
}

// ---------------------------------------------------------------------------
// T1 — doc com correspondência 1:1 no dev (metadado copiado de dev 3f6e853e)
// T2 — arquivos nativos do prod: adicionar aqui após curadoria de conteúdo.
//      (deixados de fora por exigirem título/categoria/keywords definidos pelo time)
// ---------------------------------------------------------------------------
const DOCS: DocSeed[] = [
  {
    title: 'Edital nº 36 Sisu+ 2026',
    description:
      'Este edital do Ministério da Educação torna público o cronograma e os procedimentos para o processo seletivo da etapa complementar Sisu+ 2026, destinado à ocupação de vagas remanescentes para ingresso no segundo semestre de 2026.',
    category_id: CAT.sisu,
    storage_path: 'documents/1781295270951_edital_n_36_sisu_2026.md',
    is_active: true,
    keywords: ['2026', 'cronograma', 'edital', 'educação superior', 'enem', 'inscrições', 'mec', 'processo seletivo', 'sisu', 'vagas'],
  },
];

async function bucketHas(storagePath: string): Promise<boolean> {
  const slash = storagePath.lastIndexOf('/');
  const dir = slash >= 0 ? storagePath.slice(0, slash) : '';
  const file = slash >= 0 ? storagePath.slice(slash + 1) : storagePath;
  const { data, error } = await db.storage.from('knowledge-base').list(dir, { search: file, limit: 100 });
  if (error) { console.warn(`  ⚠️  list ${dir}: ${error.message}`); return false; }
  return (data ?? []).some((o) => o.name === file);
}

async function restoreDoc(seed: DocSeed) {
  // Idempotência: já existe linha para este storage_path?
  const { data: existing, error: selErr } = await db
    .from('knowledge_documents')
    .select('id')
    .eq('storage_path', seed.storage_path)
    .limit(1);
  if (selErr) throw new Error(`select ${seed.storage_path}: ${selErr.message}`);
  if (existing && existing.length > 0) {
    console.log(`  ⏭  já existe: ${seed.title} (${seed.storage_path})`);
    return;
  }

  // Sanidade: o arquivo precisa estar no bucket
  if (!(await bucketHas(seed.storage_path))) {
    console.warn(`  ⚠️  PULADO — arquivo ausente no bucket: ${seed.storage_path}`);
    return;
  }

  // INSERT do documento (created_by = null: o usuário do dev não existe em prod auth.users)
  const { data: doc, error: docErr } = await db
    .from('knowledge_documents')
    .insert({
      title: seed.title,
      description: seed.description,
      category_id: seed.category_id,
      partner_id: null,
      storage_path: seed.storage_path,
      is_active: seed.is_active,
      current_version: 1,
      created_by: null,
    })
    .select('id')
    .single();
  if (docErr) throw new Error(`insert doc ${seed.title}: ${docErr.message}`);
  const id = doc!.id as string;

  // Versão 1
  const { error: verErr } = await db.from('knowledge_document_versions').insert({
    document_id: id,
    version_number: 1,
    storage_path: seed.storage_path,
    change_summary: 'Restauração pós-ADR-0021',
    created_by: null,
  });
  if (verErr) throw new Error(`insert version ${seed.title}: ${verErr.message}`);

  // Keywords
  if (seed.keywords.length > 0) {
    const rows = seed.keywords.map((k) => ({ document_id: id, keyword: k.toLowerCase().trim() })).filter((r) => r.keyword !== '');
    const { error: kwErr } = await db.from('knowledge_keywords').insert(rows);
    if (kwErr) throw new Error(`insert keywords ${seed.title}: ${kwErr.message}`);
  }

  console.log(`  ✅ restaurado: ${seed.title} (id=${id}, ${seed.keywords.length} keywords)`);
}

async function main() {
  console.log('🚀 Restauração da base de conhecimento — PROD');
  console.log(`   PROD: ${URL}`);
  console.log(`   Docs a processar: ${DOCS.length}\n`);

  for (const seed of DOCS) {
    await restoreDoc(seed);
  }

  // Validação final
  const tables = ['knowledge_documents', 'knowledge_document_versions', 'knowledge_keywords'];
  console.log('\n🔍 Contagens em prod:');
  for (const t of tables) {
    const { count } = await db.from(t).select('*', { count: 'exact', head: true });
    console.log(`   ${t.padEnd(30)} ${count ?? '?'}`);
  }
  console.log('\n✅ Concluído.');
}

main().catch((err) => {
  console.error('❌ Erro fatal:', err);
  process.exit(1);
});

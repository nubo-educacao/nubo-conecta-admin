/**
 * promote-sisu-v2-prod.ts
 * Repointa o documento "Edital nº 36 Sisu+ 2026" para o arquivo correto (versão maior):
 *   documents/1781527989000_edital_n_36_sisu_2026.md  (41718 B)
 * Cria registro de versão e incrementa current_version. Service role. Idempotente.
 */
import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }
const db = createClient(URL, KEY, { auth: { persistSession: false } });

const DOC_ID = 'f5b5d3e0-97a0-403a-95b0-8c75b71bfce6';
const NEW_PATH = 'documents/1781527989000_edital_n_36_sisu_2026.md';

async function main() {
  const { data: doc, error } = await db.from('knowledge_documents')
    .select('storage_path, current_version').eq('id', DOC_ID).single();
  if (error) throw new Error(error.message);

  if (doc!.storage_path === NEW_PATH) { console.log('⏭  já aponta para o arquivo correto'); return; }

  const nextVersion = (doc!.current_version as number) + 1;

  const { error: vErr } = await db.from('knowledge_document_versions').insert({
    document_id: DOC_ID, version_number: nextVersion, storage_path: NEW_PATH,
    change_summary: 'Correção: edital completo (arquivo maior)', created_by: null,
  });
  if (vErr) throw new Error(`version: ${vErr.message}`);

  const { error: uErr } = await db.from('knowledge_documents')
    .update({ storage_path: NEW_PATH, current_version: nextVersion, updated_at: new Date().toISOString() })
    .eq('id', DOC_ID);
  if (uErr) throw new Error(`update: ${uErr.message}`);

  console.log(`✅ Sisu+ repointado para ${NEW_PATH} (v${nextVersion})`);
}

main().catch((e) => { console.error('❌', e); process.exit(1); });

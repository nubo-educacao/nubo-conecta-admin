/**
 * upload-autoconhecimento-prod.ts
 * Sobe o markdown de autoconhecimento da Cloudinha para o bucket knowledge-base do PROD.
 * Idempotente (upsert). Usa SERVICE ROLE KEY.
 *
 * Uso:
 *   PROD_SUPABASE_URL=... PROD_SUPABASE_SERVICE_KEY=... \
 *   npx tsx scripts/upload-autoconhecimento-prod.ts
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';
import { resolve } from 'path';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }

const LOCAL = resolve(process.cwd(), '../cloudinha-conecta-agent/content/autoconhecimento_nubo_cloudinha.md');
const DEST = 'documents/autoconhecimento_nubo_cloudinha.md';

async function main() {
  const db = createClient(URL, KEY, { auth: { persistSession: false } });
  const content = readFileSync(LOCAL, 'utf8');
  console.log(`📄 ${LOCAL} (${content.length} bytes) → knowledge-base/${DEST}`);

  const { error } = await db.storage
    .from('knowledge-base')
    .upload(DEST, new Blob([content], { type: 'text/markdown' }), { upsert: true, contentType: 'text/markdown' });
  if (error) throw new Error(error.message);

  // Confirmar
  const { data } = await db.storage.from('knowledge-base').list('documents', { search: 'autoconhecimento_nubo_cloudinha.md' });
  console.log('✅ Upload OK. Objeto no bucket:', (data ?? []).map((o) => o.name));
}

main().catch((e) => { console.error('❌', e); process.exit(1); });

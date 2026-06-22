/**
 * compare-sisu-files.ts — só leitura. Compara o conteúdo do edital Sisu+ entre dev e prod.
 * Uso: DEV_URL=.. DEV_KEY=.. PROD_URL=.. PROD_KEY=.. npx tsx scripts/compare-sisu-files.ts
 */
import { createClient } from '@supabase/supabase-js';
import { createHash } from 'crypto';

const dev = createClient(process.env.DEV_URL!, process.env.DEV_KEY!, { auth: { persistSession: false } });
const prod = createClient(process.env.PROD_URL!, process.env.PROD_KEY!, { auth: { persistSession: false } });

async function grab(label: string, client: any, path: string) {
  const { data, error } = await client.storage.from('knowledge-base').download(path);
  if (error || !data) { console.log(`\n## ${label}\n  ❌ ${error?.message ?? 'sem dados'} (${path})`); return; }
  const text = new TextDecoder('utf-8').decode(await data.arrayBuffer());
  const sha = createHash('sha256').update(text).digest('hex').slice(0, 12);
  console.log(`\n## ${label}\n  path: ${path}\n  bytes: ${text.length}  sha: ${sha}`);
  console.log('  head:', JSON.stringify(text.slice(0, 180)));
}

async function main() {
  await grab('DEV  1781295270951 (doc Sisu+ do dev)', dev, 'documents/1781295270951_edital_n_36_sisu_2026.md');
  await grab('PROD 1781295270951 (pequeno)', prod, 'documents/1781295270951_edital_n_36_sisu_2026.md');
  await grab('PROD 1781527989000 (grande)', prod, 'documents/1781527989000_edital_n_36_sisu_2026.md');
}
main().catch((e) => { console.error('❌', e); process.exit(1); });

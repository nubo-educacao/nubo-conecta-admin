/**
 * harden-prompt-sql-rules-prod.ts
 * Injeta no prompt cloudinha_react (prod) as regras de SQL anti-`;` e de colunas
 * de knowledge_documents. Idempotente. Service role.
 */
import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }
const db = createClient(URL, KEY, { auth: { persistSession: false } });

const ANCHOR = '## REGRAS DE SQL\n- Use APENAS as colunas listadas no SCHEMA acima. Nunca invente colunas.';
const ADDED =
  '\n- NUNCA termine a query com ponto-e-vírgula (;): a query é embrulhada como subquery e o ; gera erro de sintaxe.' +
  '\n- Em `knowledge_documents` use apenas: `title`, `description`, `storage_path`, `partner_id`, `category_id`, `is_active`. NÃO existe coluna `category`.';

async function main() {
  const { data, error } = await db.from('agent_prompts')
    .select('system_instruction').eq('agent_key', 'cloudinha_react').single();
  if (error) throw new Error(error.message);
  let si = data!.system_instruction as string;

  if (si.includes('ponto-e-vírgula')) { console.log('⏭  regras de SQL já presentes'); return; }
  if (!si.includes(ANCHOR)) { console.log('⚠️  âncora "## REGRAS DE SQL" não encontrada — revisar manualmente'); return; }

  si = si.replace(ANCHOR, ANCHOR + ADDED);
  const { error: upErr } = await db.from('agent_prompts').update({ system_instruction: si }).eq('agent_key', 'cloudinha_react');
  if (upErr) throw new Error(upErr.message);
  console.log('✅ regras de SQL (anti-; e colunas knowledge_documents) injetadas no prompt');
}
main().catch((e) => { console.error('❌', e); process.exit(1); });

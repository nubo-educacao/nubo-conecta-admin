/**
 * harden-prompt-storagepath-prod.ts
 * Adiciona ao prompt cloudinha_react (aifz) a regra: nunca inventar storage_path.
 * Idempotente. Service role.
 */
import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }
const db = createClient(URL, KEY, { auth: { persistSession: false } });

const ANCHOR = 'Leia o conteúdo com `download_knowledge_document(storage_path)`. É OBRIGATÓRIO ler o documento antes de responder sobre regras/critérios/prazos — nunca responda de cabeça.';
const ADDED = ' NUNCA invente o `storage_path`: use exatamente o valor retornado por `query_educational_catalog` (coluna `storage_path` de `knowledge_documents`) ou o caminho exato já visto antes nesta conversa. Se o download falhar, refaça o `query_educational_catalog` para obter o caminho correto — não chute nomes de arquivo.';

async function main() {
  const { data, error } = await db.from('agent_prompts')
    .select('system_instruction').eq('agent_key', 'cloudinha_react').single();
  if (error) throw new Error(error.message);
  let si = data!.system_instruction as string;

  if (si.includes('NUNCA invente o `storage_path`')) { console.log('⏭  regra de storage_path já presente'); return; }
  if (!si.includes(ANCHOR)) { console.log('⚠️  âncora da regra de KB não encontrada — revisar manualmente'); return; }

  si = si.replace(ANCHOR, ANCHOR + ADDED);
  const { error: upErr } = await db.from('agent_prompts').update({ system_instruction: si }).eq('agent_key', 'cloudinha_react');
  if (upErr) throw new Error(upErr.message);
  console.log('✅ regra anti-alucinação de storage_path injetada no prompt');
}
main().catch((e) => { console.error('❌', e); process.exit(1); });

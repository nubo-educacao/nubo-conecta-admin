/**
 * harden-prompt-docrule-prod.ts
 * Adiciona uma REGRA DE OURO terminante na seção OBRIGAÇÃO ABSOLUTA do prompt
 * cloudinha_react: nunca chamar download_knowledge_document sem antes obter o
 * storage_path via query_educational_catalog. Idempotente. Service role.
 */
import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }
const db = createClient(URL, KEY, { auth: { persistSession: false } });

// Âncora: fim do item 4 (REGRA DE OURO de inscrições/links)
const ANCHOR = 'reforce que a inscrição é pelo Nubo Conecta.';
const MARKER = 'REGRA DE OURO DE DOCUMENTOS';
const ADDED =
  '\n5. ⛔ REGRA DE OURO DE DOCUMENTOS: para ler qualquer documento com `download_knowledge_document`, você DEVE PRIMEIRO obter o `storage_path` REAL chamando `query_educational_catalog` em `knowledge_documents` ' +
  "(ex.: `SELECT storage_path FROM knowledge_documents WHERE title ILIKE '%nubo conecta%' OR description ILIKE '%nubo conecta%' LIMIT 1`). " +
  "É TERMINANTEMENTE PROIBIDO chamar `download_knowledge_document` com um caminho inventado — NUNCA adivinhe nomes de arquivo (ex.: 'nubo_conecta_overview.md', 'bip_impulsiona_2026.md'). " +
  'Use APENAS um `storage_path` retornado por uma query nesta conversa. Se a query não retornar nenhuma linha, diga honestamente que não há documento sobre o tema — não invente caminho nem conteúdo.';

async function main() {
  const { data, error } = await db.from('agent_prompts')
    .select('system_instruction').eq('agent_key', 'cloudinha_react').single();
  if (error) throw new Error(error.message);
  let si = data!.system_instruction as string;

  if (si.includes(MARKER)) { console.log('⏭  regra de documentos já presente'); return; }
  if (!si.includes(ANCHOR)) { console.log('⚠️  âncora (item 4) não encontrada — revisar manualmente'); return; }

  // Inserir logo após o item 4
  si = si.replace(ANCHOR, ANCHOR + ADDED);
  const { error: upErr } = await db.from('agent_prompts').update({ system_instruction: si }).eq('agent_key', 'cloudinha_react');
  if (upErr) throw new Error(upErr.message);
  console.log('✅ REGRA DE OURO DE DOCUMENTOS adicionada à OBRIGAÇÃO ABSOLUTA');
}
main().catch((e) => { console.error('❌', e); process.exit(1); });

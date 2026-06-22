/**
 * harden-prompt-catalog-search-prod.ts
 * Adiciona regras de busca no catálogo ao prompt cloudinha_react (aifz):
 * nome de curso fica em `title`; nunca inventar valores de colunas categóricas.
 * Idempotente. Service role.
 */
import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }
const db = createClient(URL, KEY, { auth: { persistSession: false } });

const ANCHOR = '- NÃO filtre oportunidades por `status` (a view já mostra só as visíveis).';
const MARKER = 'Nome de curso/área';
const ADDED =
  '\n- Nome de curso/área (ex.: Direito, Medicina, Enfermagem) fica na coluna `title` — filtre com `title ILIKE \'%termo%\'`. NUNCA filtre nome de curso por `category`, `type` ou `opportunity_type`.' +
  '\n- NUNCA invente valores de colunas categóricas. Em `v_unified_opportunities`, `type` e `opportunity_type` têm poucos valores (ex.: `sisu`, `partner`, `programa educacional`) — NÃO use \'curso\'/\'graduação\'. Se precisar filtrar por um campo categórico cujos valores você não conhece (`type`, `opportunity_type`, `category`, `location`), descubra-os primeiro com `SELECT DISTINCT <coluna> FROM v_unified_opportunities LIMIT 20`.' +
  '\n- Use o MÍNIMO de filtros. Evite combinar `AND` com colunas categóricas adivinhadas — isso zera o resultado. Em caso de dúvida, busque só por `title ILIKE`.';

async function main() {
  const { data, error } = await db.from('agent_prompts')
    .select('system_instruction').eq('agent_key', 'cloudinha_react').single();
  if (error) throw new Error(error.message);
  let si = data!.system_instruction as string;

  if (si.includes(MARKER)) { console.log('⏭  regras de busca de catálogo já presentes'); return; }
  if (!si.includes(ANCHOR)) { console.log('⚠️  âncora (regra de status) não encontrada — revisar manualmente'); return; }

  si = si.replace(ANCHOR, ANCHOR + ADDED);
  const { error: upErr } = await db.from('agent_prompts').update({ system_instruction: si }).eq('agent_key', 'cloudinha_react');
  if (upErr) throw new Error(upErr.message);
  console.log('✅ regras de busca de catálogo (title vs categóricas) injetadas no prompt');
}
main().catch((e) => { console.error('❌', e); process.exit(1); });

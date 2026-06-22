/**
 * apply-knowledge-partner-fix-prod.ts
 * Aplica a parte DML da correção da relação knowledge_documents↔partner_opportunities
 * no PROD (service role). A parte DDL (FK + get_knowledge_documents) roda no SQL Editor.
 *
 * Faz (idempotente):
 *  1) institutions Insper / Fundação Behring (is_partner=true)
 *  2) partner_opportunities Insper / Fundação Behring
 *  3) backfill knowledge_documents.partner_id (BIP / Insper / Behring por storage_path)
 *  4) prompt cloudinha_react: injeta regra de routing da base de conhecimento
 *
 * Uso: PROD_SUPABASE_URL=... PROD_SUPABASE_SERVICE_KEY=... npx tsx scripts/apply-knowledge-partner-fix-prod.ts
 */
import { createClient } from '@supabase/supabase-js';

const URL = process.env.PROD_SUPABASE_URL!;
const KEY = process.env.PROD_SUPABASE_SERVICE_KEY!;
if (!URL || !KEY) { console.error('❌ Faltam PROD_SUPABASE_URL / PROD_SUPABASE_SERVICE_KEY'); process.exit(1); }
const db = createClient(URL, KEY, { auth: { persistSession: false } });

const PARTNERS = ['Insper', 'Fundação Behring'];
const BACKFILL: Record<string, string> = {
  'BIP Impulsiona': 'documents/1781465432669_regulamento_bip_impulsiona.md',
  'Insper': 'documents/1776968975352_edital_processo_seletivo_insper_20262.md',
  'Fundação Behring': 'documents/1774649670990_edital_fundacao_behring.md',
};

async function ensureInstitution(name: string): Promise<string> {
  const { data: ex } = await db.from('institutions').select('id').eq('name', name).limit(1);
  if (ex && ex.length) return ex[0].id as string;
  const { data, error } = await db.from('institutions').insert({ name, is_partner: true }).select('id').single();
  if (error) throw new Error(`institution ${name}: ${error.message}`);
  console.log(`  ✅ institution criada: ${name}`);
  return data!.id as string;
}

async function ensureOpportunity(name: string, institutionId: string): Promise<string> {
  const { data: ex } = await db.from('partner_opportunities').select('id').eq('name', name).limit(1);
  if (ex && ex.length) { console.log(`  ⏭  opportunity já existe: ${name}`); return ex[0].id as string; }
  const { data, error } = await db.from('partner_opportunities')
    .insert({ institution_id: institutionId, name, opportunity_type: 'programa de bolsa', status: 'inactive' })
    .select('id').single();
  if (error) throw new Error(`opportunity ${name}: ${error.message}`);
  console.log(`  ✅ opportunity criada: ${name}`);
  return data!.id as string;
}

async function main() {
  console.log('🚀 Correção da relação knowledge↔partner_opportunities (DML) — PROD\n');

  // 1+2) institutions + opportunities
  const oppId: Record<string, string> = {};
  for (const name of PARTNERS) {
    const instId = await ensureInstitution(name);
    oppId[name] = await ensureOpportunity(name, instId);
  }
  // BIP já existe
  const { data: bip } = await db.from('partner_opportunities').select('id').eq('name', 'BIP Impulsiona').limit(1);
  if (bip && bip.length) oppId['BIP Impulsiona'] = bip[0].id as string;

  // 3) backfill
  console.log('\n🔗 Backfill partner_id:');
  for (const [partner, path] of Object.entries(BACKFILL)) {
    const id = oppId[partner];
    if (!id) { console.log(`  ⚠️  ${partner}: oportunidade ausente, pulado`); continue; }
    const { data, error } = await db.from('knowledge_documents')
      .update({ partner_id: id }).eq('storage_path', path).select('id');
    if (error) throw new Error(`backfill ${partner}: ${error.message}`);
    console.log(`  ${data && data.length ? '✅' : '⏭ '} ${partner} → ${data?.length ?? 0} doc(s)`);
  }

  // 4) prompt routing da base de conhecimento
  console.log('\n📝 Prompt cloudinha_react:');
  const { data: pr, error: prErr } = await db.from('agent_prompts')
    .select('system_instruction').eq('agent_key', 'cloudinha_react').single();
  if (prErr) throw new Error(`read prompt: ${prErr.message}`);
  const anchor = '### Pergunta sobre PARCEIROS ou OPORTUNIDADES DE PARCEIROS?\n→ Use `query_educational_catalog` em `partners` e/ou `partner_opportunities`';
  let si = pr!.system_instruction as string;
  if (si.includes('### Pergunta sobre EDITAIS, REGRAS')) {
    console.log('  ⏭  já contém a regra de base de conhecimento');
  } else if (!si.includes(anchor)) {
    console.log('  ⚠️  âncora não encontrada — não modifiquei (revisar manualmente)');
  } else {
    const block = anchor +
      '\n\n### Pergunta sobre EDITAIS, REGRAS, DOCUMENTOS ou COMO FUNCIONA um programa (ProUni, Sisu, parceiros)?' +
      '\n→ 1) Encontre o documento em `knowledge_documents` via `query_educational_catalog` (filtre por `title`/`description` com ILIKE ou pelas keywords). Pegue o `storage_path`.' +
      '\n→ 2) Para documentos de um parceiro específico, junte `knowledge_documents.partner_id = partner_opportunities.id` (ex.: BIP Impulsiona) para achar o doc certo.' +
      '\n→ 3) Leia o conteúdo com `download_knowledge_document(storage_path)`. É OBRIGATÓRIO ler o documento antes de responder sobre regras/critérios/prazos — nunca responda de cabeça.';
    si = si.replace(anchor, block);
    const { error: upErr } = await db.from('agent_prompts').update({ system_instruction: si }).eq('agent_key', 'cloudinha_react');
    if (upErr) throw new Error(`update prompt: ${upErr.message}`);
    console.log('  ✅ regra de base de conhecimento injetada');
  }

  console.log('\n✅ DML aplicado. Falta rodar a DDL (FK + get_knowledge_documents) no SQL Editor.');
}

main().catch((e) => { console.error('❌', e); process.exit(1); });

import postgres from 'postgres';
import fs from 'fs';
import path from 'path';

// Configuração PROD
const DB_URL = 'postgres://postgres:SYK80OGPcr0C06xp@db.aifzkybxhmefbirujvdg.supabase.co:6543/postgres?sslmode=require';
const sql = postgres(DB_URL, { ssl: 'require' });

async function restoreSisuDocument() {
  try {
    console.log("=== Restaurando Documento Sisu no PROD (T1) ===");

    // Verifica se já existe pelo storage_path
    const storagePath = "documents/1781295270951_edital_n_36_sisu_2026.md";
    const [existing] = await sql`
      SELECT id, title FROM knowledge_documents WHERE storage_path = ${storagePath}
    `;

    if (existing) {
      console.log(`Documento já existe no PROD com ID ${existing.id}. Ignorando criação para evitar duplicatas.`);
      return;
    }

    const keywords = ['sisu', 'edital', 'mec', 'enem', 'vagas', 'educação superior', '2026', 'processo seletivo', 'cronograma', 'inscrições'];
    
    // Chama o RPC para recriar o metadado (atomic)
    const [result] = await sql`
      SELECT manage_knowledge_document(
        p_id := NULL,
        p_title := 'Edital nº 36 Sisu+ 2026',
        p_description := 'Este edital do Ministério da Educação torna público o cronograma e os procedimentos para o processo seletivo da etapa complementar Sisu+ 2026, destinado à ocupação de vagas remanescentes para ingresso no segundo semestre de 2026.',
        p_category_id := '069d2144-8e8f-4951-a271-0820f6b4f875',
        p_partner_id := NULL,
        p_storage_path := ${storagePath},
        p_is_active := true,
        p_keywords := ${keywords},
        p_change_summary := 'Restauração da base de conhecimento (T1)',
        p_delete := false
      ) as res
    `;

    console.log("Resultado da Inserção (RPC manage_knowledge_document):");
    console.log(result.res);
    
  } catch (error) {
    console.error("Erro ao restaurar documento Sisu:", error);
  } finally {
    await sql.end();
  }
}

restoreSisuDocument();

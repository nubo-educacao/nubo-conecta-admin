import { createClient } from '@supabase/supabase-js';

// Para executar, adicione as variáveis no .env ou exporte no terminal
const DEV_URL = process.env.VITE_SUPABASE_URL_DEV || process.env.NEXT_PUBLIC_SUPABASE_URL_DEV;
const DEV_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY_DEV;
const PROD_URL = process.env.VITE_SUPABASE_URL_PROD || process.env.NEXT_PUBLIC_SUPABASE_URL_PROD;
const PROD_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY_PROD;

if (!DEV_URL || !DEV_KEY || !PROD_URL || !PROD_KEY) {
  console.error("Erro: Variáveis de ambiente DEV e PROD (URL e SERVICE_ROLE_KEY) não encontradas.");
  process.exit(1);
}

const supabaseDev = createClient(DEV_URL, DEV_KEY);
const supabaseProd = createClient(PROD_URL, PROD_KEY);

const TABLES_TO_MIGRATE = [
  'institutions',
  'campus',
  'courses',
  'programs',
  'opportunities',
  'partner_institutions',
  'partner_opportunities',
  'important_dates'
];

async function migrateData() {
  console.log("Iniciando migração de dados (DEV -> PROD) com estratégia de UPSERT...");

  for (const table of TABLES_TO_MIGRATE) {
    console.log(`\n--- Processando tabela: ${table} ---`);
    
    // Paginação para evitar limite de memória/payload
    let page = 0;
    const pageSize = 1000;
    let hasMore = true;
    let totalMigrated = 0;

    while (hasMore) {
      const { data, error } = await supabaseDev
        .from(table)
        .select('*')
        .range(page * pageSize, (page + 1) * pageSize - 1);

      if (error) {
        console.error(`Erro ao buscar ${table} no DEV:`, error.message);
        break; // Passa para a próxima tabela em caso de erro
      }

      if (data && data.length > 0) {
        // Upsert na Produção
        const { error: upsertError } = await supabaseProd
          .from(table)
          .upsert(data);

        if (upsertError) {
          console.error(`Erro ao fazer upsert em ${table} no PROD:`, upsertError.message);
          break; // Aborta paginação se houver erro crítico de upsert
        }

        totalMigrated += data.length;
        console.log(`Migrados ${data.length} registros (Total: ${totalMigrated})`);
        
        if (data.length < pageSize) {
          hasMore = false;
        } else {
          page++;
        }
      } else {
        hasMore = false;
        if (page === 0) console.log(`Nenhum dado encontrado em DEV para a tabela ${table}.`);
      }
    }
    
    console.log(`Tabela ${table} finalizada. Total migrado: ${totalMigrated}`);
  }

  console.log("\n✅ Migração concluída! Os IDs das vagas foram mantidos, garantindo a integridade com as candidaturas de Prod.");
}

migrateData().catch(console.error);

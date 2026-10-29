import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// As RPCs public.etl_* (clonar ciclo, rollback, stop, importar ProUni/SiSU/e-MEC)
// são SECURITY DEFINER e estavam com EXECUTE para PUBLIC e anon em produção: a
// chave anon pública apagava ou reimportava ciclos. O admin chama todas com a
// sessão do usuário, então só authenticated e service_role mantêm EXECUTE.

const migration = readFileSync(
  resolve("supabase/migrations/20261029160000_revoke_etl_rpcs_anon.sql"),
  "utf8",
);
const service = readFileSync(resolve("src/services/etlPipelineService.ts"), "utf8");

describe("RPCs public.etl_*", () => {
  it("cobrem toda função etl_ do schema public", () => {
    expect(migration).toMatch(/nspname\s*=\s*'public'/);
    expect(migration).toMatch(/proname\s+LIKE\s+'etl\\_%'/);
  });

  it("perdem EXECUTE de PUBLIC e anon", () => {
    expect(migration).toMatch(/REVOKE\s+EXECUTE\s+ON\s+FUNCTION\s+%s\s+FROM\s+PUBLIC,\s*anon/i);
  });

  it("mantêm EXECUTE só para authenticated e service_role", () => {
    expect(migration).toMatch(/GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+%s\s+TO\s+authenticated,\s*service_role'/i);
    expect(migration).not.toMatch(/GRANT[^;]*\b(anon|PUBLIC)\b/i);
  });

  it("falham a migration se alguma continuar executável por anon", () => {
    expect(migration).toMatch(/has_function_privilege\('anon',\s*p\.oid,\s*'EXECUTE'\)/);
    expect(migration).toMatch(/RAISE\s+EXCEPTION/);
  });

  it("são chamadas pelo admin com o client da sessão do usuário", () => {
    expect(service).toMatch(/import\s*\{\s*supabase\s*\}\s*from\s*'@\/integrations\/supabase\/client'/);
    expect(service).not.toMatch(/createTempClient|service_role|SERVICE_ROLE/);
    expect(service).toMatch(/supabase\.rpc\('etl_rollback_log'/);
    expect(service).toMatch(/supabase\.rpc\('etl_stop_log'/);
  });
});

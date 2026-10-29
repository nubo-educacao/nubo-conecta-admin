import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

// A Cloudinha grava agent_errors.session_id com o id de sessão do chat
// (ex.: "4ll12zt0hhhmvpzhxob"), que não é uuid. Com a coluna em uuid — como no
// production_baseline.sql — todo insert falhava e nenhum erro do agente ficava
// registrado desde 30/05/2026. Alguma migration posterior precisa deixá-la como text.

const migrationsDir = resolve("supabase/migrations");

describe("agent_errors.session_id", () => {
  it("é text (aceita os ids de sessão da Cloudinha)", () => {
    const changesToText = readdirSync(migrationsDir)
      .filter((f) => f.endsWith(".sql"))
      .some((f) =>
        /ALTER\s+TABLE\s+(public\.)?agent_errors\s+ALTER\s+COLUMN\s+session_id\s+(SET\s+DATA\s+)?TYPE\s+text/i.test(
          readFileSync(resolve(migrationsDir, f), "utf8"),
        ),
      );
    expect(changesToText).toBe(true);
  });
});

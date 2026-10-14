import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

// Contrato da versão VIGENTE de public.calculate_match: a última migration que a
// (re)define é a que está em produção. Em 20260828100000 a função passou a ler
// `SELECT weights FROM match_config`, mas match_config é chave/valor
// (weight_key, weight_value, is_active) — todo cálculo de match falhava com
// `column "weights" does not exist` (e ainda course_groups.course_names e
// cities.population, que também não existem).

const migrationsDir = resolve("supabase/migrations");

function currentCalculateMatchBody(): { file: string; body: string } {
  const files = readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .sort();
  for (const file of [...files].reverse()) {
    const sql = readFileSync(resolve(migrationsDir, file), "utf8");
    const start = sql.search(/CREATE OR REPLACE FUNCTION public\.calculate_match\(/);
    if (start === -1) continue;
    // corpo entre delimitadores $tag$ ($$ ou $function$)
    const open = /AS\s+(\$[A-Za-z_]*\$)/.exec(sql.slice(start));
    if (!open) throw new Error(`corpo de calculate_match não encontrado em ${file}`);
    const bodyStart = start + open.index + open[0].length;
    const bodyEnd = sql.indexOf(open[1], bodyStart);
    return { file, body: sql.slice(bodyStart, bodyEnd) };
  }
  throw new Error("nenhuma migration define public.calculate_match");
}

describe("calculate_match vigente", () => {
  const { file, body } = currentCalculateMatchBody();

  it(`lê os pesos de match_config como chave/valor (${file})`, () => {
    expect(body).not.toMatch(/SELECT\s+weights\s+INTO/i);
    expect(body).toMatch(
      /jsonb_object_agg\(\s*weight_key\s*,\s*weight_value\s*\)\s+INTO\s+v_weights\s+FROM\s+public\.match_config\s+WHERE\s+is_active\s*=\s*true/i,
    );
  });

  it("usa os pesos padrão quando match_config está vazio", () => {
    expect(body).toMatch(/IF\s+v_weights\s+IS\s+NULL\s+THEN\s+v_weights\s*:=/i);
  });

  it("usa course_groups.courses (não existe course_names)", () => {
    expect(body).not.toMatch(/course_names/);
    expect(body).toMatch(/cg\.courses\s*@>\s*ARRAY\[UPPER\(ci\)\]/);
  });

  it("não ordena cidades por population (coluna inexistente)", () => {
    expect(body).not.toMatch(/population/);
  });

  it("respeita o academic_score_floor configurado no Simulador de Match", () => {
    expect(body).toMatch(
      /v_academic_floor\s*:=\s*COALESCE\(\(v_weights->>'academic_score_floor'\)::NUMERIC,\s*50(\.0)?\)/i,
    );
  });
});

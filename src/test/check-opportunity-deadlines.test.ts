// NUB-RD-75c / ADR-0024 — contrato da Edge Function check-opportunity-deadlines.
//
// O cron só vale como aceite se a chamada for autenticada pelo segredo
// dedicado, se falhas virarem HTTP de erro (e não 200 com zeros) e se a
// repetição não duplicar alerta pending.
import { describe, it, expect } from "vitest";
import {
  handleDeadlineRequest,
  type DeadlineClient,
} from "../../supabase/functions/check-opportunity-deadlines/core";

type Row = Record<string, unknown>;

interface FakeOptions {
  secretStatus?: string;
  rpcError?: { message: string };
  tables?: Record<string, Row[]>;
  selectError?: Record<string, { message: string }>;
  insertError?: { code?: string; message: string };
}

function fakeClient(opts: FakeOptions = {}) {
  const inserted: Row[] = [];
  const rpcCalls: Array<{ fn: string; args: Row }> = [];

  const client: DeadlineClient = {
    rpc: async (fn, args) => {
      rpcCalls.push({ fn, args });
      if (opts.rpcError) return { data: null, error: opts.rpcError };
      return { data: opts.secretStatus ?? "ok", error: null };
    },
    from: (table) => {
      const filters: Array<[string, unknown]> = [];
      const builder = {
        select: () => builder,
        eq: (col: string, val: unknown) => {
          filters.push([col, val]);
          return builder;
        },
        not: () => builder,
        lte: () => builder,
        gte: () => builder,
        limit: () => builder,
        insert: async (row: Row) => {
          if (opts.insertError) return { error: opts.insertError };
          inserted.push(row);
          return { error: null };
        },
        then: (resolve: (v: unknown) => void) => {
          const err = opts.selectError?.[table];
          if (err) return resolve({ data: null, error: err });
          let rows = table === "admin_alerts" ? inserted : (opts.tables?.[table] ?? []);
          if (table === "admin_alerts") {
            rows = rows.filter((r) =>
              filters.every(([c, v]) => (c === "status" ? v === "pending" : r[c] === v)),
            );
          }
          return resolve({ data: rows, error: null });
        },
      };
      return builder as never;
    },
  };
  return { client, inserted, rpcCalls };
}

const NOW = new Date("2026-10-15T08:00:00Z");
const inTwoDays = "2026-10-17T03:00:00Z";

const eligibleDate = {
  id: "11111111-1111-1111-1111-111111111111",
  title: "[QA-75c] fixture",
  type: "sisu",
  start_date: inTwoDays,
  end_date: null,
};

function req(headers: Record<string, string> = {}) {
  return new Request("https://x.supabase.co/functions/v1/check-opportunity-deadlines", {
    method: "POST",
    headers,
  });
}

describe("check-opportunity-deadlines — autenticação do cron", () => {
  it("sem header x-cron-secret responde 401 e não consulta nada", async () => {
    const { client, rpcCalls } = fakeClient();
    const res = await handleDeadlineRequest(req(), client, NOW);
    expect(res.status).toBe(401);
    expect(rpcCalls).toHaveLength(0);
  });

  it("segredo inválido responde 401 sem gerar alertas", async () => {
    const { client, inserted } = fakeClient({
      secretStatus: "invalid",
      tables: { important_dates: [eligibleDate] },
    });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "errado" }), client, NOW);
    expect(res.status).toBe(401);
    expect(inserted).toHaveLength(0);
  });

  it("segredo não provisionado no Vault responde 503 com mensagem operacional", async () => {
    const { client } = fakeClient({ secretStatus: "not_configured" });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "qualquer" }), client, NOW);
    expect(res.status).toBe(503);
    expect(await res.text()).toMatch(/cron_check_deadlines_secret/);
  });

  it("valida o segredo pela RPC do Vault, nunca por variável de ambiente", async () => {
    const { client, rpcCalls } = fakeClient();
    await handleDeadlineRequest(req({ "x-cron-secret": "s3" }), client, NOW);
    expect(rpcCalls[0]).toEqual({ fn: "cron_deadlines_secret_status", args: { p_secret: "s3" } });
  });

  it("não ecoa o segredo recebido na resposta", async () => {
    const { client } = fakeClient({ secretStatus: "invalid" });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "segredo-xyz" }), client, NOW);
    expect(await res.text()).not.toContain("segredo-xyz");
  });
});

describe("check-opportunity-deadlines — efeito e falha explícita", () => {
  it("important_date elegível gera admin_alert pending e responde 200 com contagens", async () => {
    const { client, inserted } = fakeClient({ tables: { important_dates: [eligibleDate] } });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.alerts_inserted).toBe(1);
    expect(inserted[0]).toMatchObject({
      alert_type: "mec_period_start",
      entity_type: "important_date",
      entity_id: eligibleDate.id,
    });
    expect(inserted[0]).not.toHaveProperty("status");
  });

  it("repetição não duplica: alerta pending existente é deduplicado", async () => {
    const { client, inserted } = fakeClient({ tables: { important_dates: [eligibleDate] } });
    await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    const body = await res.json();
    expect(inserted).toHaveLength(1);
    expect(body.alerts_inserted).toBe(0);
    expect(body.alerts_deduplicated).toBe(1);
  });

  it("violação do índice único (23505) conta como deduplicado, não como erro", async () => {
    const { client } = fakeClient({
      tables: { important_dates: [eligibleDate] },
      insertError: { code: "23505", message: "duplicate key" },
    });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    expect(res.status).toBe(200);
    expect((await res.json()).alerts_deduplicated).toBe(1);
  });

  it("erro de leitura responde 500 em vez de 200 com zeros", async () => {
    const { client } = fakeClient({ selectError: { programs: { message: "boom" } } });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    expect(res.status).toBe(500);
    expect(await res.text()).toMatch(/programs/);
  });

  it("erro de insert diferente de 23505 responde 500", async () => {
    const { client } = fakeClient({
      tables: { important_dates: [eligibleDate] },
      insertError: { code: "42501", message: "permission denied" },
    });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    expect(res.status).toBe(500);
  });

  it("falha da RPC de segredo responde 500", async () => {
    const { client } = fakeClient({ rpcError: { message: "rpc down" } });
    const res = await handleDeadlineRequest(req({ "x-cron-secret": "ok" }), client, NOW);
    expect(res.status).toBe(500);
  });
});

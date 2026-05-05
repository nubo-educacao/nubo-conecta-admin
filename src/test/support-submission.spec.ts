// BDD E2E Tests — Sprint 1.0: Track C (QA & Automations)
// Card: E2E Test: Validar preenchimento do formulário de Bug gerando Card no Snaps
// Card: E2E Test: Validar preenchimento do formulário de Feature Request
//
// CONTRATO DURO:
//   POST /public/projects/cards → 201
//   Response body contém card_type correto e id válido.
//
// fetch é mockado globalmente — nenhuma chamada HTTP real ao Snaps.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createSupportCard, type CreateCardPayload } from "@/lib/snapsClient";

// ---------------------------------------------------------------------------
// Fetch mock global
// ---------------------------------------------------------------------------

const mockFetch = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", mockFetch);
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
// Helper: Response 201
// ---------------------------------------------------------------------------
function make201(body: object): Response {
  return new Response(JSON.stringify(body), {
    status: 201,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Cenário: Bug Report
// ---------------------------------------------------------------------------
describe("Cenário: Bug — createSupportCard com card_type=bug", () => {
  const bugPayload: CreateCardPayload = {
    title: "[Bug] Modal de suporte não fecha após envio",
    description: JSON.stringify({
      environment: "production",
      steps_to_reproduce: "1. Acessar /suporte\n2. Abrir modal\n3. Preencher e enviar",
      expected_behavior: "Modal fecha e card aparece no board",
      actual_behavior: "Modal permanece aberto sem feedback",
      severity: "high",
    }),
    card_type: "bug",
  };

  it("Given: client configurado — When: E2E submete bug válido — Then: request bate em /public/projects/cards com POST", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-bug-001", card_type: "bug", title: bugPayload.title, status: "todo", sprint_id: "" }),
    );

    await createSupportCard(bugPayload);

    expect(mockFetch).toHaveBeenCalledOnce();
    const [calledUrl, options] = mockFetch.mock.calls[0] as [string, RequestInit];

    expect(calledUrl).toContain("/public/projects/cards");
    expect(options.method).toBe("POST");
  });

  it("And: header x-api-key está presente na requisição", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-bug-002", card_type: "bug", title: bugPayload.title, status: "todo", sprint_id: "" }),
    );

    await createSupportCard(bugPayload);

    const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
    const headers = options.headers as Record<string, string>;
    expect(headers["x-api-key"]).toBeDefined();
    expect(headers["Content-Type"]).toBe("application/json");
  });

  it("And: body serializado contém card_type=bug e o payload RCA", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-bug-003", card_type: "bug", title: bugPayload.title, status: "todo", sprint_id: "" }),
    );

    await createSupportCard(bugPayload);

    const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(options.body as string) as CreateCardPayload;

    expect(body.card_type).toBe("bug");
    expect(body.title).toBe(bugPayload.title);
    // description deve conter o payload RCA estruturado
    expect(body.description).toContain("steps_to_reproduce");
    expect(body.description).toContain("severity");
  });

  it("And: response retorna card com id válido e card_type=bug", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-bug-004", card_type: "bug", title: bugPayload.title, status: "todo", sprint_id: "" }),
    );

    const result = await createSupportCard(bugPayload);

    expect(result.id).toBe("card-bug-004");
    expect(result.card_type).toBe("bug");
  });

  it("Negative contract: lança erro quando API retorna 401", async () => {
    mockFetch.mockResolvedValueOnce(
      new Response("Unauthorized", { status: 401 }),
    );

    await expect(createSupportCard(bugPayload)).rejects.toThrow("Snaps API error 401");
  });
});

// ---------------------------------------------------------------------------
// Cenário: Feature Request
// ---------------------------------------------------------------------------
describe("Cenário: Feature Request — createSupportCard com card_type=feature", () => {
  const featurePayload: CreateCardPayload = {
    title: "[Melhoria] Filtro de modalidade de bolsa no catálogo",
    description: JSON.stringify({
      pain_point: "Usuários não conseguem filtrar por Prouni/Sisu/FIES.",
      expected_impact: "Redução estimada de 30% no tempo de busca.",
      priority: "high",
    }),
    card_type: "feature",
  };

  it("Given: client configurado — When: E2E submete feature request válida — Then: request bate em /public/projects/cards com POST", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-feat-001", card_type: "feature", title: featurePayload.title, status: "todo", sprint_id: "" }),
    );

    await createSupportCard(featurePayload);

    expect(mockFetch).toHaveBeenCalledOnce();
    const [calledUrl, options] = mockFetch.mock.calls[0] as [string, RequestInit];

    expect(calledUrl).toContain("/public/projects/cards");
    expect(options.method).toBe("POST");
  });

  it("And: body serializado contém card_type=feature e campos pain_point / expected_impact", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-feat-002", card_type: "feature", title: featurePayload.title, status: "todo", sprint_id: "" }),
    );

    await createSupportCard(featurePayload);

    const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(options.body as string) as CreateCardPayload;

    expect(body.card_type).toBe("feature");
    expect(body.description).toContain("pain_point");
    expect(body.description).toContain("expected_impact");
  });

  it("And: response retorna card com id válido e card_type=feature", async () => {
    mockFetch.mockResolvedValueOnce(
      make201({ id: "card-feat-003", card_type: "feature", title: featurePayload.title, status: "todo", sprint_id: "" }),
    );

    const result = await createSupportCard(featurePayload);

    expect(result.id).toBe("card-feat-003");
    expect(result.card_type).toBe("feature");
  });

  it("Negative contract: lança erro quando API retorna 422 (payload inválido)", async () => {
    mockFetch.mockResolvedValueOnce(
      new Response("Validation failed", { status: 422 }),
    );

    await expect(createSupportCard(featurePayload)).rejects.toThrow("Snaps API error 422");
  });
});

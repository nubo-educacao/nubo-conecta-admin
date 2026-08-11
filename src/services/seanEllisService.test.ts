import { supabase } from "@/integrations/supabase/client";
import {
  getSeanEllisData,
  getSeanEllisStats,
  importSeanEllisData,
  mapSeanEllisCsvRows,
} from "./seanEllisService";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: vi.fn() },
}));

const filters = {
  fullName: "Ana",
  city: "Rio",
  education: "Ensino médio",
  isNuboStudent: true,
  incomeMin: 500,
  incomeMax: 1500,
  quotaTypes: ["PPI"],
};

describe("Sean Ellis QA", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(supabase.rpc).mockResolvedValue({ data: {}, error: null } as never);
  });

  it("mapeia o CSV do Google Forms para o contrato de importação", async () => {
    const row = {
      "Carimbo de data/hora": "04/02/2026 20:04:04",
      "Qual seu nome completo?": "Ana Nubo",
      "Qual seu Whatsapp?": "21 99999-0000",
      "Você se inscreveu no SISU 2026?": "Sim",
      "Se a Cloudinha deixasse de existir, como você se sentiria?": "Muito desapontado(a)",
    };

    expect(mapSeanEllisCsvRows([row])).toEqual([
      expect.objectContaining({
        submitted_at: "04/02/2026 20:04:04",
        full_name: "Ana Nubo",
        whatsapp_raw: "21 99999-0000",
        sisu_subscribed: "Sim",
        disappointment_level: "Muito desapontado(a)",
      }),
    ]);

    vi.mocked(supabase.rpc).mockResolvedValue({
      data: { success: true, count: 1 },
      error: null,
    } as never);
    await importSeanEllisData([row]);

    expect(supabase.rpc).toHaveBeenCalledWith("import_sean_ellis_data", {
      data: expect.arrayContaining([
        expect.objectContaining({ full_name: "Ana Nubo" }),
      ]),
    });
  });

  it("mantém filtros idênticos entre tabela paginada e estatísticas", async () => {
    await getSeanEllisData(3, 20, filters, "submitted_at", "desc");
    await getSeanEllisStats(filters);

    const sharedParams = {
      p_filter_name: "Ana",
      p_filter_city: "Rio",
      p_filter_education: "Ensino médio",
      p_filter_is_nubo_student: true,
      p_filter_income_min: 500,
      p_filter_income_max: 1500,
      p_filter_quota_types: ["PPI"],
    };

    expect(supabase.rpc).toHaveBeenNthCalledWith(
      1,
      "get_sean_ellis_data",
      expect.objectContaining({
        ...sharedParams,
        p_page: 3,
        p_page_size: 20,
      }),
    );
    expect(supabase.rpc).toHaveBeenNthCalledWith(
      2,
      "get_sean_ellis_stats",
      sharedParams,
    );
  });
});

import { supabase } from "@/integrations/supabase/client";

export interface MatchWeight {
  id: string;
  weight_key: string;
  weight_value: number;
  description: string | null;
  category: string | null;
  is_active: boolean;
}

export interface SimulationInput {
  enem_score: number | null;
  family_income_per_capita: number | null;
  course_interest: string[];
  quota_types: string[];
  state_preference: string | null;
}

export interface SimulationResult {
  unified_opportunity_id: string;
  title: string;
  provider_name: string;
  match_score: number;
  is_partner: boolean;
  match_details: Record<string, number>;
}

export const getMatchWeights = async (): Promise<MatchWeight[]> => {
  const { data, error } = await supabase
    .from("match_config")
    .select("*")
    .order("weight_key", { ascending: true });

  if (error) {
    console.error("Error fetching match weights:", error);
    throw error;
  }

  return data as MatchWeight[];
};

export const updateMatchWeight = async (id: string, value: number): Promise<void> => {
  const { error } = await supabase
    .from("match_config")
    .update({ weight_value: value } as any)
    .eq("id", id);

  if (error) {
    console.error("Error updating match weight:", error);
    throw error;
  }
};

/**
 * Simulator function that mimics the RPC `calculate_match`. 
 * It runs completely on the frontend using locally loaded weights and a small batch of opportunities,
 * which helps test changes without writing to DB or invoking RPC for fake profiles.
 */
export const simulateMatchFrontend = async (input: SimulationInput, weights: MatchWeight[]): Promise<SimulationResult[]> => {
  // To avoid fetching all opportunities, we request a sample of 20 random opportunities
  // 10 partners and 10 MEC
  const { data: opps, error } = await supabase
    .from("v_unified_opportunities")
    .select("unified_id, is_partner")
    .limit(50); // Get a batch of 50 just to simulate

  if (error) {
    console.error("Error fetching opportunities for simulation:", error);
    throw error;
  }

  // Weight dictionary
  const weightMap: Record<string, number> = {};
  for (const w of weights) {
    if (w.is_active) {
      weightMap[w.weight_key] = w.weight_value;
    }
  }

  const results: SimulationResult[] = [];

  for (const opp of opps) {
    // Componente ENEM
    const enemWeight = weightMap['enem_weight'] ?? 0.35;
    const enemComponent = input.enem_score && input.enem_score > 0
        ? Math.min(100, (input.enem_score / 700) * 100)
        : 50;

    // Componente Renda
    const incomeWeight = weightMap['income_weight'] ?? 0.20;
    const incomeComponent = input.family_income_per_capita !== null ? 70 : 50;

    // Componente Área de Interesse
    const interestWeight = weightMap['course_interest_weight'] ?? 0.20;
    const interestComponent = input.course_interest.length > 0 ? 80 : 40;

    // Componente Localização
    const locationWeight = weightMap['location_weight'] ?? 0.15;
    const locationComponent = 50;

    // Componente Cotas
    const quotaWeight = weightMap['quota_weight'] ?? 0.10;
    const quotaComponent = input.quota_types.length > 0 ? 75 : 50;

    let baseScore = (enemWeight * enemComponent) +
                    (incomeWeight * incomeComponent) +
                    (interestWeight * interestComponent) +
                    (locationWeight * locationComponent) +
                    (quotaWeight * quotaComponent);

    baseScore = Math.max(0, Math.min(100, baseScore));

    let finalScore = baseScore;
    let boostApplied = false;

    if (opp.is_partner) {
        const partnerBoost = weightMap['partner_boost'] ?? 1.15;
        const partnerBoostCap = weightMap['partner_boost_cap'] ?? 20.0;
        finalScore = Math.min(
            baseScore * partnerBoost,
            baseScore + partnerBoostCap
        );
        boostApplied = true;
    }

    results.push({
      unified_opportunity_id: opp.unified_id,
      title: opp.is_partner ? "Oportunidade Parceira" : "Oportunidade MEC",
      provider_name: "Mock Provider",
      match_score: Number(finalScore.toFixed(2)),
      is_partner: opp.is_partner,
      match_details: {
        base_score: Number(baseScore.toFixed(2)),
        enem_component: enemComponent,
        partner_boosted: boostApplied ? 1 : 0
      }
    });
  }

  // Rank by match_score descending
  results.sort((a, b) => b.match_score - a.match_score);

  return results.slice(0, 10); // Return top 10 for simulation
};

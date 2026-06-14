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
  preferred_shifts: string[];
  university_preference: string | null;
  program_preference: string | null;
}

export interface SimulationResult {
  unified_opportunity_id: string;
  title: string;
  provider_name: string;
  match_score: number;
  is_partner: boolean;
  match_details: {
    meets_income: boolean;
    academic_score: number;
    shift_score: number;
    inst_program_score: number;
    course_score: number;
    distance_score: number;
    base_score: number;
    is_partner: boolean;
    boost_applied: boolean;
    idle_vacancy_boost_applied: boolean;
    opportunity_type: string;
  };
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
 * Simulator function that mirrors the V3 multi-factorial RPC `calculate_match`.
 * Runs completely on the frontend using locally loaded weights and a batch of opportunities.
 * Pillars: Performance (40%), Preferences (30%), Location (20%), Boosts (extra).
 */
export const simulateMatchFrontend = async (input: SimulationInput, weights: MatchWeight[]): Promise<SimulationResult[]> => {
  const { data: opps, error } = await supabase
    .from("v_unified_opportunities")
    .select("unified_id, title, provider_name, is_partner, type, min_cutoff_score_current, min_cutoff_score_prev, location")
    .limit(50);

  if (error) {
    console.error("Error fetching opportunities for simulation:", error);
    throw error;
  }

  const w: Record<string, number> = {};
  for (const wt of weights) {
    if (wt.is_active) w[wt.weight_key] = wt.weight_value;
  }

  const SM = 1518.00;
  const perfWeight = w['performance_weight'] ?? 0.40;
  const prefWeight = w['preference_weight'] ?? 0.30;
  const locWeight = w['location_weight'] ?? 0.20;
  const partnerBoost = w['partner_boost'] ?? 1.15;
  const partnerBoostCap = w['partner_boost_cap'] ?? 20.0;

  const results: SimulationResult[] = [];

  for (const opp of opps) {
    const oppType = (opp as any).type as string;
    const isPartner = opp.is_partner;

    // ── Pilar 1: Income eligibility ──
    let meetsIncome = true;
    if (input.family_income_per_capita != null) {
      if (oppType === 'prouni' && input.family_income_per_capita > SM * 3.0) meetsIncome = false;
      // SISU always has Ampla Concorrência (no income limit), so we do not block the course-level match.
    }

    const decayAbove = w['score_decay_above_cutoff'] ?? 0.3;
    const decayBelow = w['score_decay_below_cutoff'] ?? 0.9;

    const cutoff = ((opp as any).min_cutoff_score_current ?? (opp as any).min_cutoff_score_prev) as number | null;
    let academicScore = 50.0;
    if (input.enem_score && input.enem_score > 0) {
      if (cutoff && cutoff > 0) {
        const diff = input.enem_score - cutoff;
        const penalty = diff >= 0 ? diff * decayAbove : (-diff) * decayBelow;
        academicScore = Math.max(0, Math.min(100, 100 - penalty));
      } else {
        academicScore = Math.min(100, (input.enem_score / 700) * 100);
      }
    }

    // ── Pilar 2: Preferences ──
    const shiftScore = 50.0; // No shift data in unified view for frontend sim
    const instProgScore =
      (input.university_preference === 'publica' && oppType === 'sisu' ? 100 :
       input.university_preference === 'privada' && oppType !== 'sisu' ? 100 : 50) / 2 +
      (input.program_preference === 'sisu' && oppType === 'sisu' ? 100 :
       input.program_preference === 'prouni' && oppType === 'prouni' ? 100 : 50) / 2;

    const courseScore = input.course_interest.length > 0
      ? (input.course_interest.some(ci => ((opp as any).title as string)?.toLowerCase().includes(ci.toLowerCase())) ? 100 : 10)
      : 50;

    // ── Pilar 3: Location ──
    const distanceScore = 40.0; // No lat/lon in frontend sim
    const regionalBonus = input.state_preference && (opp as any).location?.toLowerCase().includes(input.state_preference.toLowerCase()) ? 30 : 0;

    // ── Composite ──
    let baseScore = 0;
    if (meetsIncome) {
      baseScore = Math.max(0, Math.min(100,
        perfWeight * academicScore +
        prefWeight * ((shiftScore * 0.333) + (instProgScore * 0.333) + (courseScore * 0.334)) +
        locWeight * Math.min(100, distanceScore + regionalBonus)
      ));
    }

    // ── Pilar 4: Boosts ──
    let finalScore = baseScore;
    let boostApplied = false;
    if (isPartner && meetsIncome) {
      finalScore = Math.min(baseScore * partnerBoost, baseScore + partnerBoostCap);
      boostApplied = true;
    }
    finalScore = Math.min(100, finalScore);

    results.push({
      unified_opportunity_id: (opp as any).unified_id,
      title: (opp as any).title ?? (isPartner ? "Oportunidade Parceira" : "Oportunidade MEC"),
      provider_name: (opp as any).provider_name ?? "—",
      match_score: Number(finalScore.toFixed(2)),
      is_partner: isPartner,
      match_details: {
        meets_income: meetsIncome,
        academic_score: Number(academicScore.toFixed(2)),
        shift_score: shiftScore,
        inst_program_score: Number(instProgScore.toFixed(2)),
        course_score: courseScore,
        distance_score: distanceScore,
        base_score: Number(baseScore.toFixed(2)),
        is_partner: isPartner,
        boost_applied: boostApplied,
        idle_vacancy_boost_applied: false,
        opportunity_type: oppType,
      },
    });
  }

  results.sort((a, b) => b.match_score - a.match_score);
  return results.slice(0, 20);
};

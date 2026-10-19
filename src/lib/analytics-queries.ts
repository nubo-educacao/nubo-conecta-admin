import { supabase } from "@/integrations/supabase/client";
import { attributionRpcArgs, hasAttributionFilter, type AttributionFilter } from "@/lib/attributionFilter";
import { attributionEdgeBody } from "@/lib/commandCenterAttribution";

export interface DateRange {
  from?: Date;
  to?: Date;
}

export interface PowerUser {
  userId: string;
  userName: string;
  userPhone: string;
  accessCount: number;
}

export interface DashboardStats {
  totalRegistered: number;
  activeUsers: number;
  activeUsersWithMessages: number;
  catalogUsers: number;
  activeUsersChange?: number;
  catalogUsersChange?: number;
  totalMessages: number;
  messagesChange?: number;
  totalFavorites: number;
  favoritesChange?: number;
  errorsToday?: number;
  errorsChange?: number;
  powerUsers: number;
  powerUsersChange?: number;
  powerUsersList: PowerUser[];
}

export interface ActivityData {
  label: string;
  mensagens: number;
  usuarios: number;
}

export interface CourseInterest {
  name: string;
  searches: number;
  buscas?: number;
}

export interface FunnelStep {
  etapa: string;
  valor: number;
  label?: string;
  value?: number;
  color?: string;
  description?: string;
  user_ids?: string[];
}

export interface UserPreference {
  name: string;
  value: number;
  color?: string;
}

export interface ErrorLog {
  id: string;
  type: "error" | "warning" | "info";
  message: string;
  count: number;
  time: string;
  timestamp?: string;
  error_type?: string;
  errorType?: string;
  resolved?: boolean;
  recoveryAttempted?: boolean;
  stackTrace?: string;
  endpoint?: string;
  metadata?: Record<string, unknown>;
  sessionId?: string;
  userId?: string;
  createdAt?: string;
}

export interface TopUser {
  id: string;
  name: string;
  messages: number;
  favorites: number;
  score: number;
  sessions: number;
  user_id?: string;
  full_name?: string;
  message_count?: number;
  favorites_count?: number;
}

export interface LocationData {
  name: string;
  count: number;
  city?: string;
  state?: string;
}

// Fetch dashboard statistics via Edge Function
// Recorte first-touch (campanha/divulgador): os campos só vão no corpo com filtro ativo.
export async function fetchDashboardStats(dateRange?: DateRange, attribution?: AttributionFilter): Promise<DashboardStats> {
  const { data, error } = await supabase.functions.invoke('analytics-stats', {
    body: { dateRange, ...attributionEdgeBody(attribution) },
  });

  if (error) {
    console.error('Error fetching dashboard stats:', error);
    throw error;
  }

  return data as DashboardStats;
}

// Fetch activity data (last 7 days)
export async function fetchActivityData(dateRange?: DateRange, attribution?: AttributionFilter): Promise<ActivityData[]> {
  const { data, error } = await supabase.functions.invoke('analytics-activity', { body: { mode: 'week', dateRange, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, ...attributionEdgeBody(attribution) } });

  if (error) {
    console.error('Error fetching activity data:', error);
    throw error;
  }

  return data as ActivityData[];
}

// Fetch top courses by interest
export async function fetchTopCourses(attribution?: AttributionFilter): Promise<CourseInterest[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'courses', ...attributionEdgeBody(attribution) },
  });

  if (response.error) {
    console.error('Error fetching top courses:', response.error);
    throw response.error;
  }

  return response.data as CourseInterest[];
}

// ── Saúde do Match & Demografia (TP-1 1B / ADR-0027) ────────────────────────
//
// Substitui o funil linear, removido daqui. A ADR-0023 foi deprecada e a
// ADR-0027 move funil para os dashboards de domínio (MEC e parceiro), que são
// separados. Match não é etapa de funil — é saúde do motor, e vira pizza.

/**
 * Origem de um item de raça/escola (NUB-RD-92). "(por cota)" é inferência a
 * partir da cota declarada, nunca autodeclaração, e vem em item próprio.
 */
export type DemographicSource = 'self_declared' | 'quota_inferred' | 'unanswered';

export interface DistributionSlice {
  label: string;
  value: number;
  /** Só em race/school_type, a partir do NUB-RD-92. */
  source?: DemographicSource;
}

// with_match = concluiu Match alguma vez (v0 ∪ v1, incluindo elegibilidade de
// parceiro) desde o complemento do card f245da71. Os campos opcionais são
// aditivos e ainda não são exibidos.
export interface MatchHealth {
  with_match: number;
  without_match: number;
  total: number;
  attempted_no_result?: number;
  never?: number;
  with_current_result?: number;
  with_current_mec_result?: number;
}

/** Contagem por origem do valor exibido numa dimensão. */
export interface DimensionProvenance {
  profile: number;
  partner_form: number;
  unanswered: number;
  conflicts: number;
}

/**
 * Diagnóstico da inferência por cota (NUB-RD-92). quota_unmapped = perfis com
 * ao menos um token fora do mapeamento; quota_conflict = escola pública e bolsa
 * integral juntas, sem inferência. Não são parcelas da cobertura.
 */
export interface QuotaProvenance {
  quota_inferred?: number;
  quota_unmapped?: number;
}

export interface DemographicsProvenance {
  rule_version: string;
  education: DimensionProvenance;
  race: DimensionProvenance & QuotaProvenance & { declined: number };
  school_type: DimensionProvenance & QuotaProvenance & { quota_conflict?: number };
  income: DimensionProvenance & { onboarding_v0: number; sm_band: number };
}

/**
 * Cobertura por perfil único: self_declared + quota_inferred + uncovered =
 * total_users. Percentuais são null quando total_users = 0.
 */
export interface DimensionCoverage {
  total_users: number;
  self_declared: number;
  quota_inferred: number;
  uncovered: number;
  self_declared_pct: number | null;
  quota_inferred_pct: number | null;
  uncovered_pct: number | null;
  covered_pct: number | null;
}

export interface DemographicsCoverage {
  /** declined ("Prefiro não informar") é subconjunto de uncovered. */
  race: DimensionCoverage & { declined: number };
  school_type: DimensionCoverage;
}

/**
 * Snapshot do estado atual (todo o histórico), recortável só por first-touch.
 * Não tem período.
 */
export interface CommandCenterDemographics {
  match_health: MatchHealth;
  education: DistributionSlice[];
  income: DistributionSlice[];
  race: DistributionSlice[];
  school_type: DistributionSlice[];
  provenance?: DemographicsProvenance;
  coverage?: DemographicsCoverage;
}

/**
 * Uma RPC, um round-trip, cinco distribuições — em vez de 4 varreduras da mesma
 * tabela com os mesmos joins. Devolve apenas contagens agregadas e exige
 * is_backoffice_admin() no banco.
 */
export async function fetchCommandCenterDemographics(attribution?: AttributionFilter): Promise<CommandCenterDemographics> {
  // Sem filtro, a chamada é exatamente a de antes (só o nome); com filtro, os
  // três p_filter_* do contrato TP-7.
  const { data, error } = attribution && hasAttributionFilter(attribution)
    ? await (supabase.rpc as any)('get_command_center_demographics', attributionRpcArgs(attribution))
    : await (supabase.rpc as any)('get_command_center_demographics');

  if (error) {
    console.error('Error fetching command center demographics:', error);
    throw error;
  }

  return data as CommandCenterDemographics;
}

// Fetch user preferences distribution
export async function fetchUserPreferences(attribution?: AttributionFilter): Promise<UserPreference[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'preferences', ...attributionEdgeBody(attribution) },
  });

  if (response.error) {
    console.error('Error fetching user preferences:', response.error);
    throw response.error;
  }

  return response.data as UserPreference[];
}

// Fetch error logs
export async function fetchErrorLogs(filters?: {
  type?: string;
  status?: string;
  limit?: number;
}): Promise<ErrorLog[]> {
  const { data, error } = await supabase.functions.invoke('analytics-errors', {
    body: filters || {},
  });

  if (error) {
    console.error('Error fetching error logs:', error);
    throw error;
  }

  return data as ErrorLog[];
}

// Fetch top engaged users
export async function fetchTopUsers(dateRange?: DateRange, attribution?: AttributionFilter): Promise<TopUser[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'users', dateRange, ...attributionEdgeBody(attribution) },
  });

  if (response.error) {
    console.error('Error fetching top users:', response.error);
    throw response.error;
  }

  return response.data as TopUser[];
}

// Fetch location data
export async function fetchLocationData(attribution?: AttributionFilter): Promise<LocationData[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'locations', ...attributionEdgeBody(attribution) },
  });

  if (response.error) {
    console.error('Error fetching location data:', response.error);
    throw response.error;
  }

  return response.data as LocationData[];
}

// Fixtures do contrato congelado TP-D rev.3 (src/types/productAnalytics.ts).
// Taxas são frações (1 = 100%); null = indisponível.
import type { ActivityCoverage, L1Metrics, L2Metrics, NsmMetrics, NsmWindow } from "@/types/productAnalytics";

export const activityCoverage: ActivityCoverage = {
  capture_mode: "daily_snapshot+live_union",
  granularity: "day",
  timezone: "America/Sao_Paulo",
  capture_started_at: "2026-10-19T22:00:00Z",
  last_successful_capture_at: "2026-10-20T06:17:00Z",
  first_observed_by_source: {
    session: "2026-01-17T13:00:00Z",
    engagement: "2026-03-02T13:00:00Z",
    chat: "2025-08-01T13:00:00Z",
  },
  limitation: "Sessões removidas entre coletas e dias sem evidência não são reconstruíveis; datas diárias BRT, sem precisão horária.",
};

const activityPeriod = {
  from: "2026-09-21T03:00:00Z",
  to: "2026-10-21T03:00:00Z",
  granularity: "day" as const,
  timezone: "America/Sao_Paulo" as const,
};

export const l1Fixture = (): L1Metrics => ({
  active_users: 136,
  cloudinha_adoption: { talked: 34, active: 136, rate: 0.25, n: 136 },
  time_to_first_application: { n: 12, median_days: 3.5, p75_days: 9, basis: "profile_created_to_application_started" },
  retention_by_semester: [
    { semester: "2025-S2", active: 80, retained_next: 30, rate: 0.375, complete: true },
    { semester: "2026-S1", active: 120, retained_next: 48, rate: null, complete: false },
  ],
  coverage: { activity: activityCoverage, excluded_negative_durations: 2, activity_period: activityPeriod, rates_unit: "fraction" },
});

export const l2Fixture = (): L2Metrics => ({
  engine_reach: {
    mec: { active_with_match: 60, active: 136, rate: 60 / 136 },
    partner: { active_with_match: 0, active: 0, rate: null },
  },
  catalog_coverage: {
    mec: { recommended: 900, catalog: 210952, rate: 900 / 210952 },
    partner: { recommended: 7, catalog: 8, rate: 7 / 8 },
  },
  match_contribution: {
    temporal: {
      conversions_with_prior_match: 3,
      conversions_total: 11,
      rate: 3 / 11,
      since: "2026-10-19T22:00:00Z",
      coverage: { status: "observed", capture_failures: 1, note: "Taxa observada; janelas com falha de captura não são completas." },
    },
    untimed_association: { count: 40, label: "associação sem ordem temporal", scope: "Conversões anteriores ao ledger com match atual" },
  },
  scope: {
    snapshot_at: "2026-10-20T12:00:00Z",
    engine_reach: "ativos no período com resultado atual",
    catalog_coverage: "oportunidades recomendadas no snapshot atual ÷ catálogo atual",
    identity: "perfil titular comprovado",
  },
  coverage: { activity: activityCoverage, activity_period: activityPeriod, excluded_unresolved_profile: 5, post_capture_missing_snapshot: 0 },
});

const nsmWindow = (semester: string, over: Partial<NsmWindow> = {}): NsmWindow => ({
  semester,
  range: { from: "2026-07-01T03:00:00Z", to: "2027-01-01T03:00:00Z" },
  active_users: 100,
  active_users_source: { activity_days: 80, live_fallback: 50, deduplicated_total: 100 },
  referrals: { total: 42, composition: { mec_redirect: 12, partner_redirected: 25, partner_submitted: 5, legacy_external_redirect: 9 } },
  per_active_user: 0.42,
  coverage: {
    activity: activityCoverage,
    mec_redirect: { status: "instrumented", verified_since: "2026-10-01T03:00:00Z", first_observed_at: "2026-10-01T12:00:00Z" },
    reason: null,
    application_time_basis: { captured_terminal: 4, created_at_proxy: 26, post_capture_missing_snapshot: 0 },
  },
  ...over,
});

export const nsmFixture = (semester = "2026-S2", compare = "2025-S2", over: Partial<NsmWindow> = {}): NsmMetrics => ({
  ...nsmWindow(semester, over),
  comparison: nsmWindow(compare, {
    active_users: 70,
    active_users_source: { activity_days: 0, live_fallback: 70, deduplicated_total: 70 },
    referrals: { total: 21, composition: { mec_redirect: 0, partner_redirected: 18, partner_submitted: 3, legacy_external_redirect: 30 } },
    per_active_user: null,
    coverage: {
      activity: activityCoverage,
      mec_redirect: { status: "not_instrumented", verified_since: "2026-10-01T03:00:00Z" },
      reason: "incomplete_mec_coverage",
      application_time_basis: { captured_terminal: 0, created_at_proxy: 21, post_capture_missing_snapshot: 0 },
    },
  }),
  seasonality_note: semester.slice(-1) !== compare.slice(-1)
    ? "S1 tem SiSU+ProUni; S2 só ProUni"
    : "Comparação com o mesmo semestre; coberturas históricas podem diferir",
});

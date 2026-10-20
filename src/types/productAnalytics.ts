/** Frozen TP-D rev.3 contract. Rates are fractions (1 = 100%); null means unavailable. */
export interface AnalyticsRange { from?: Date; to?: Date }
export type CoverageStatus = 'unknown'|'not_instrumented'|'partial'|'instrumented'|'observed';
export interface InstrumentationCoverage {
 verified_since?: string|null; first_observed_at?: string|null; capture_started_at?: string|null;
 status: CoverageStatus; partial?: boolean; reason?: string|null;
}
export interface ActivityCoverage {
 capture_mode:'daily_snapshot+live_union'; granularity:'day'; timezone:'America/Sao_Paulo';
 capture_started_at:string|null;last_successful_capture_at:string|null;
 first_observed_by_source:Partial<Record<'session'|'engagement'|'chat',string>>|null;limitation:string;
}
export type FunnelStepKey='card_view'|'card_click'|'terminal';
export interface GlobalStep {key:FunnelStepKey;label:string;events:number;users:number;coverage:InstrumentationCoverage}
export interface VolumeRatio {from:FunnelStepKey;to:FunnelStepKey;events_ratio:number|null;users_ratio:number|null;kind:'observed_volume_ratio'}
export interface DomainFunnel {
 steps:GlobalStep[];volume_ratios:VolumeRatio[];
 composition_events:{redirected:number;submitted:number;legacy_external_redirect:number}|null;
}
export interface GlobalFunnel {
 period:{from:string|null;to:string};unit_note:string;domains:{mec:DomainFunnel;partner:DomainFunnel};
 totals_by_step:{key:FunnelStepKey;events:number;distinct_identities:number;domain_identity_sum:number;people_composition_additive:false;coverage:InstrumentationCoverage}[];
 by_surface:{surface:string|null;domain:'mec'|'partner';views:number;clicks:number;clicks_instrumented:number;coverage:InstrumentationCoverage}[];
}
export interface NsmWindow {
 semester:string;range:{from:string;to:string};active_users:number;
 active_users_source:{activity_days:number;live_fallback:number;deduplicated_total:number};
 referrals:{total:number;composition:{mec_redirect:number;partner_redirected:number;partner_submitted:number;legacy_external_redirect:number}};
 per_active_user:number|null;
 coverage:{activity:ActivityCoverage;mec_redirect:InstrumentationCoverage;reason:string|null;
 application_time_basis:{captured_terminal:number;created_at_proxy:number;post_capture_missing_snapshot:number}};
}
export interface NsmMetrics extends NsmWindow {comparison:NsmWindow;seasonality_note:string}
export interface L1Metrics {
 active_users:number;cloudinha_adoption:{talked:number;active:number;rate:number|null;n:number};
 time_to_first_application:{n:number;median_days:number|null;p75_days:number|null;basis:'profile_created_to_application_started'};
 retention_by_semester:{semester:string;active:number;retained_next:number;rate:number|null;complete:boolean}[];
 coverage:{activity:ActivityCoverage;excluded_negative_durations:number;activity_period:{from:string|null;to:string|null;granularity:'day'};rates_unit:'fraction'};
}
export interface L2Metrics {
 engine_reach:Record<'mec'|'partner',{active_with_match:number;active:number;rate:number|null}>;
 catalog_coverage:Record<'mec'|'partner',{recommended:number;catalog:number;rate:number|null}>;
 match_contribution:{temporal:{conversions_with_prior_match:number;conversions_total:number;rate:number|null;since:string|null;coverage:{status:CoverageStatus;note:string}};
 untimed_association:{count:number;label:'associação sem ordem temporal';scope:string}};
 scope:{snapshot_at:string;engine_reach:string;catalog_coverage:string;identity:string};
 coverage:{activity:ActivityCoverage;excluded_unresolved_profile:number;post_capture_missing_snapshot:number};
}
export interface MecVolumeRow {
 unified_opportunity_id:string;entity_id:string;course_title:string|null;institution_name:string|null;
 location:string|null;type:string|null;card_view:number;card_click:number;redirect:number;distinct_users:number;distinct_identities:number;in_catalog:boolean;
}
export interface MecVolumes {total_count:number;limit:number;offset:number;order:'views'|'clicks'|'redirects'|'users';rows:MecVolumeRow[];non_additive_notice:string}

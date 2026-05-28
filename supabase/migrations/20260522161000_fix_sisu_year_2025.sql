-- Sprint 13.0 Hotfix — Fix Sisu Year 2025
-- Sisu database records are from 2025, but the view and match engine were looking for 2026.

DROP MATERIALIZED VIEW IF EXISTS v_unified_opportunities CASCADE;

CREATE MATERIALIZED VIEW v_unified_opportunities AS
 SELECT sisu_branch.unified_id,
    sisu_branch.title,
    sisu_branch.provider_name,
    sisu_branch.type,
    sisu_branch.opportunity_type,
    sisu_branch.category,
    sisu_branch.is_partner,
    sisu_branch.location,
    sisu_branch.badges,
    sisu_branch.created_at,
    sisu_branch.external_redirect_url,
    sisu_branch.external_redirect_enabled,
    sisu_branch.status,
    sisu_branch.starts_at,
    sisu_branch.ends_at,
    sisu_branch.match_score,
    sisu_branch.min_cutoff_score,
    sisu_branch.max_cutoff_score,
    sisu_branch.institution_cover_url,
    sisu_branch.nu_vagas_autorizadas,
    sisu_branch.qt_vagas_ofertadas,
    sisu_branch.qt_inscricao_2025,
    sisu_branch.vagas_ociosas_2025,
    sisu_branch.institution_id,
    sisu_branch.institution_igc,
    sisu_branch.institution_organization,
    sisu_branch.institution_category,
    sisu_branch.institution_site,
    sisu_branch.eligibility_criteria,
    sisu_branch.benefits,
    sisu_branch.brand_color,
    sisu_branch.weights,
    sisu_branch.institution_acronym
   FROM ( SELECT DISTINCT ON (c.id) 'mec_'::text || c.id::text AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'sisu'::text AS type,
            'sisu'::text AS opportunity_type,
            'public_universities'::text AS category,
            false AS is_partner,
            (cp.city || ', '::text) || cp.state AS location,
            jsonb_build_array(o.shift) - 'null'::text AS badges,
            o.created_at,
            NULL::text AS external_redirect_url,
            false AS external_redirect_enabled,
            'approved'::text AS status,
            id_dates.start_date AS starts_at,
            id_dates.end_date AS ends_at,
            NULL::numeric AS match_score,
            s.min_cutoff AS min_cutoff_score,
            s.max_cutoff AS max_cutoff_score,
            NULL::text AS institution_cover_url,
            sv.nu_vagas_autorizadas,
            sv.qt_vagas_ofertadas,
            sv.qt_inscricao_2025,
            sv.vagas_ociosas_2025,
            i.id AS institution_id,
            ie.igc AS institution_igc,
            ie.academic_organization AS institution_organization,
            ie.administrative_category AS institution_category,
            ie.site AS institution_site,
            NULL::jsonb AS eligibility_criteria,
            NULL::jsonb AS benefits,
            NULL::text AS brand_color,
            jsonb_build_object('redacao', sv.peso_redacao, 'matematica', sv.peso_matematica, 'linguagens', sv.peso_linguagens, 'humanas', sv.peso_ciencias_humanas, 'natureza', sv.peso_ciencias_natureza) AS weights,
            sis.acronym AS institution_acronym
           FROM opportunities o
             JOIN courses c ON c.id = o.course_id
             JOIN campus cp ON cp.id = c.campus_id
             JOIN institutions i ON i.id = cp.institution_id
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM opportunities
                  WHERE opportunities.opportunity_type = 'sisu'::text
                  GROUP BY opportunities.course_id) s ON s.course_id = o.course_id
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM important_dates d
                  WHERE d.type = 'sisu'::text AND d.controls_opportunity_dates = true
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON true
             LEFT JOIN opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
             LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
             LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
          WHERE o.semester = '1'::text AND o.opportunity_type = 'sisu'::text AND o.year = 2025
          ORDER BY c.id, o.created_at) sisu_branch
UNION ALL
 SELECT prouni_branch.unified_id,
    prouni_branch.title,
    prouni_branch.provider_name,
    prouni_branch.type,
    prouni_branch.opportunity_type,
    prouni_branch.category,
    prouni_branch.is_partner,
    prouni_branch.location,
    prouni_branch.badges,
    prouni_branch.created_at,
    prouni_branch.external_redirect_url,
    prouni_branch.external_redirect_enabled,
    prouni_branch.status,
    prouni_branch.starts_at,
    prouni_branch.ends_at,
    prouni_branch.match_score,
    prouni_branch.min_cutoff_score,
    prouni_branch.max_cutoff_score,
    prouni_branch.institution_cover_url,
    prouni_branch.nu_vagas_autorizadas,
    prouni_branch.qt_vagas_ofertadas,
    prouni_branch.qt_inscricao_2025,
    prouni_branch.vagas_ociosas_2025,
    prouni_branch.institution_id,
    prouni_branch.institution_igc,
    prouni_branch.institution_organization,
    prouni_branch.institution_category,
    prouni_branch.institution_site,
    prouni_branch.eligibility_criteria,
    prouni_branch.benefits,
    prouni_branch.brand_color,
    prouni_branch.weights,
    prouni_branch.institution_acronym
   FROM ( SELECT DISTINCT ON (c.id) 'mec_'::text || c.id::text AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'prouni'::text AS type,
            'prouni'::text AS opportunity_type,
            'grants_scholarships'::text AS category,
            false AS is_partner,
            (cp.city || ', '::text) || cp.state AS location,
            jsonb_build_array('100% Gratuito', o.shift) - 'null'::text AS badges,
            o.created_at,
            NULL::text AS external_redirect_url,
            false AS external_redirect_enabled,
            'approved'::text AS status,
            id_dates.start_date AS starts_at,
            id_dates.end_date AS ends_at,
            NULL::numeric AS match_score,
            s.min_cutoff AS min_cutoff_score,
            s.max_cutoff AS max_cutoff_score,
            NULL::text AS institution_cover_url,
            NULL::text AS nu_vagas_autorizadas,
            pv_agg.qt_vagas_ofertadas,
            NULL::text AS qt_inscricao_2025,
            pv_agg.vagas_ociosas_2025,
            i.id AS institution_id,
            ie.igc AS institution_igc,
            ie.academic_organization AS institution_organization,
            ie.administrative_category AS institution_category,
            ie.site AS institution_site,
            NULL::jsonb AS eligibility_criteria,
            NULL::jsonb AS benefits,
            NULL::text AS brand_color,
            NULL::jsonb AS weights,
            sis.acronym AS institution_acronym
           FROM opportunities o
             JOIN courses c ON c.id = o.course_id
             JOIN campus cp ON cp.id = c.campus_id
             JOIN institutions i ON i.id = cp.institution_id
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM opportunities
                  WHERE opportunities.opportunity_type = 'prouni'::text
                  GROUP BY opportunities.course_id) s ON s.course_id = o.course_id
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM important_dates d
                  WHERE d.type = 'prouni'::text AND d.controls_opportunity_dates = true
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON true
             LEFT JOIN LATERAL ( SELECT sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
                    sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada))::integer AS vagas_ociosas_2025
                   FROM opportunities_prouni_vacancies pv
                  WHERE pv.opportunity_id = o.id) pv_agg ON true
             LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
             LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
          WHERE o.semester = '1'::text AND o.opportunity_type = 'prouni'::text AND o.year = 2025
          ORDER BY c.id, o.created_at) prouni_branch
UNION ALL
 SELECT 'partner_'::text || po.id::text AS unified_id,
    po.name AS title,
    i.name AS provider_name,
    'partner'::text AS type,
    po.opportunity_type,
    'educational_programs'::text AS category,
    true AS is_partner,
    'Nacional'::text AS location,
    COALESCE(po.eligibility_criteria -> 'badges'::text, '[]'::jsonb) AS badges,
    po.created_at,
    po.external_redirect_config ->> 'url'::text AS external_redirect_url,
    COALESCE((po.external_redirect_config ->> 'enabled'::text)::boolean, false) AS external_redirect_enabled,
    po.status::text AS status,
    po.starts_at,
    po.ends_at,
    NULL::numeric AS match_score,
    NULL::numeric AS min_cutoff_score,
    NULL::numeric AS max_cutoff_score,
    pi.cover_url AS institution_cover_url,
    NULL::text AS nu_vagas_autorizadas,
    NULL::text AS qt_vagas_ofertadas,
    NULL::text AS qt_inscricao_2025,
    NULL::integer AS vagas_ociosas_2025,
    i.id AS institution_id,
    ie.igc AS institution_igc,
    ie.academic_organization AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site AS institution_site,
    po.eligibility_criteria,
    NULL::jsonb AS benefits,
    pi.brand_color,
    NULL::jsonb AS weights,
    sis.acronym AS institution_acronym
   FROM partner_opportunities po
     JOIN institutions i ON i.id = po.institution_id
     LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
     LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
  WHERE po.status::text = ANY (ARRAY['incoming'::text, 'opened'::text, 'closed'::text]);;

CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id ON v_unified_opportunities (unified_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_institution ON v_unified_opportunities (institution_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_type ON v_unified_opportunities (type);
GRANT SELECT ON v_unified_opportunities TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW v_unified_institutions AS
 WITH inst_opps AS (
         SELECT v_unified_opportunities.institution_id,
            array_agg(DISTINCT v_unified_opportunities.opportunity_type) AS opp_types
           FROM v_unified_opportunities
          GROUP BY v_unified_opportunities.institution_id
        )
 SELECT i.id,
    i.name,
    COALESCE(pi.location,
        CASE
            WHEN ie.city IS NOT NULL AND ie.state IS NOT NULL THEN (ie.city || ' - '::text) || ie.state
            WHEN ie.city IS NOT NULL THEN ie.city
            WHEN ie.state IS NOT NULL THEN ie.state
            ELSE ( SELECT (c.city || ' - '::text) || c.state
               FROM campus c
              WHERE c.institution_id = i.id AND c.city IS NOT NULL
             LIMIT 1)
        END) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    sisu.acronym,
        CASE
            WHEN i.is_partner IS TRUE THEN 'partner'::text
            ELSE 'mec'::text
        END AS type,
    io.opp_types,
    COALESCE(sisu.academic_organization, ie.academic_organization) AS academic_organization,
    COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category
   FROM institutions i
     LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
     LEFT JOIN institutionsinfosisu sisu ON sisu.institution_id = i.id
     LEFT JOIN inst_opps io ON io.institution_id = i.id;;

GRANT SELECT ON v_unified_institutions TO anon, authenticated, service_role;

DROP FUNCTION IF EXISTS public.calculate_match(UUID);

CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_income                NUMERIC;
    v_course_interests      TEXT[];
    v_preferred_shifts      TEXT[];
    v_university_preference TEXT;
    v_program_preference    TEXT;
    v_state_preference      TEXT;
    v_location_preference   TEXT;
    v_lat                   NUMERIC;
    v_lon                   NUMERIC;

    v_nota_linguagens        NUMERIC;
    v_nota_ciencias_humanas  NUMERIC;
    v_nota_ciencias_natureza NUMERIC;
    v_nota_matematica        NUMERIC;
    v_nota_redacao           NUMERIC;
    v_enem_avg               NUMERIC;
    v_has_enem               BOOLEAN := false;

    v_weights             JSONB;
    v_enem_window_sisu    INT     := 3;
    v_salario_minimo      NUMERIC := 1518.00;

    v_has_funnel_filters  BOOLEAN;
BEGIN
    -- 1. Load user preferences
    SELECT
        up.family_income_per_capita,
        up.course_interest,
        up.preferred_shifts,
        up.university_preference,
        up.program_preference,
        up.state_preference,
        up.location_preference,
        up.device_latitude,
        up.device_longitude
    INTO
        v_income, v_course_interests, v_preferred_shifts,
        v_university_preference, v_program_preference,
        v_state_preference, v_location_preference,
        v_lat, v_lon
    FROM public.user_preferences up
    WHERE up.user_id = p_profile_id;

    -- 2. Best ENEM scores (highest simple average, last 3 years)
    SELECT
        ues.nota_linguagens,
        ues.nota_ciencias_humanas,
        ues.nota_ciencias_natureza,
        ues.nota_matematica,
        ues.nota_redacao
    INTO
        v_nota_linguagens, v_nota_ciencias_humanas,
        v_nota_ciencias_natureza, v_nota_matematica, v_nota_redacao
    FROM public.user_enem_scores ues
    WHERE ues.user_id = p_profile_id
      AND ues.year >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - v_enem_window_sisu)
    ORDER BY (
        COALESCE(ues.nota_linguagens, 0) + COALESCE(ues.nota_ciencias_humanas, 0) +
        COALESCE(ues.nota_ciencias_natureza, 0) + COALESCE(ues.nota_matematica, 0) +
        COALESCE(ues.nota_redacao, 0)
    ) DESC
    LIMIT 1;

    IF v_nota_linguagens IS NOT NULL THEN
        v_has_enem := true;
        v_enem_avg := (
            COALESCE(v_nota_linguagens, 0) + COALESCE(v_nota_ciencias_humanas, 0) +
            COALESCE(v_nota_ciencias_natureza, 0) + COALESCE(v_nota_matematica, 0) +
            COALESCE(v_nota_redacao, 0)
        ) / 5.0;
    END IF;

    -- 3. Load match_config weights
    SELECT jsonb_object_agg(weight_key, weight_value)
    INTO v_weights
    FROM public.match_config
    WHERE is_active = true;

    IF v_weights IS NULL THEN
        v_weights := '{
            "performance_weight": 0.40,
            "preference_weight": 0.30,
            "location_weight": 0.20,
            "partner_boost": 1.15,
            "partner_boost_cap": 20,
            "idle_vacancy_boost": 5
        }'::jsonb;
    END IF;

    -- 4. Determine active funnel filters
    v_has_funnel_filters := (
        (v_program_preference IS NOT NULL AND v_program_preference != 'indiferente') OR
        (v_course_interests   IS NOT NULL AND cardinality(v_course_interests)   > 0) OR
        v_state_preference    IS NOT NULL OR
        (v_preferred_shifts   IS NOT NULL AND cardinality(v_preferred_shifts)   > 0)
    );

    -- 5. Clear old matches
    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    -- 6. Score and persist — single INSERT with UNION ALL (TOP 100 MEC + ALL partners)
    INSERT INTO public.user_opportunity_matches
        (profile_id, unified_opportunity_id, match_score, match_details)

    WITH

    -- ── MEC funnel — capped at 3000, ordered by cutoff_score DESC ────────────
    mec_funnel AS (

        -- Path A: funnel filters active
        SELECT * FROM (
            SELECT
                o.id AS opp_id,
                'mec_' || o.id::text AS unified_id,
                o.course_id,
                c.course_name,
                o.opportunity_type,
                o.scholarship_type,
                o.concurrency_type,
                o.cutoff_score,
                o.shift,
                false AS is_partner,
                cp.latitude  AS campus_lat,
                cp.longitude AS campus_lon,
                cp.state     AS campus_state,
                cp.city      AS campus_city,
                i.id         AS institution_id,
                sv.peso_linguagens,
                sv.peso_ciencias_humanas,
                sv.peso_ciencias_natureza,
                sv.peso_matematica,
                sv.peso_redacao,
                sv.vagas_ociosas_2025,
                NULL::jsonb  AS eligibility_criteria
            FROM public.opportunities o
            JOIN public.courses c       ON c.id = o.course_id
            JOIN public.campus cp       ON cp.id = c.campus_id
            JOIN public.institutions i  ON i.id = cp.institution_id
            LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
            WHERE v_has_funnel_filters
              AND o.semester = '1'
              AND (
                  (o.opportunity_type = 'sisu'   AND o.year = 2025) OR
                  (o.opportunity_type = 'prouni' AND o.year = 2025)
              )
              AND (
                  v_program_preference IS NULL OR v_program_preference = 'indiferente'
                  OR o.opportunity_type = v_program_preference
              )
              AND (
                  v_course_interests IS NULL OR cardinality(v_course_interests) = 0
                  OR EXISTS (
                      SELECT 1 FROM unnest(v_course_interests) ci
                      WHERE c.course_name ILIKE '%' || ci || '%'
                  )
              )
              AND (v_state_preference IS NULL OR cp.state = v_state_preference)
              AND (
                  v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0
                  OR o.shift = ANY(v_preferred_shifts)
              )
            ORDER BY o.cutoff_score DESC NULLS LAST
            LIMIT 3000
        ) path_a

        UNION ALL

        -- Path B: no filters, has location → haversine ≤ 500 km
        SELECT * FROM (
            SELECT
                o.id AS opp_id,
                'mec_' || o.id::text AS unified_id,
                o.course_id,
                c.course_name,
                o.opportunity_type,
                o.scholarship_type,
                o.concurrency_type,
                o.cutoff_score,
                o.shift,
                false AS is_partner,
                cp.latitude  AS campus_lat,
                cp.longitude AS campus_lon,
                cp.state     AS campus_state,
                cp.city      AS campus_city,
                i.id         AS institution_id,
                sv.peso_linguagens,
                sv.peso_ciencias_humanas,
                sv.peso_ciencias_natureza,
                sv.peso_matematica,
                sv.peso_redacao,
                sv.vagas_ociosas_2025,
                NULL::jsonb  AS eligibility_criteria
            FROM public.opportunities o
            JOIN public.courses c       ON c.id = o.course_id
            JOIN public.campus cp       ON cp.id = c.campus_id
            JOIN public.institutions i  ON i.id = cp.institution_id
            LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
            WHERE NOT v_has_funnel_filters
              AND v_lat IS NOT NULL AND v_lon IS NOT NULL
              AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
              AND o.semester = '1'
              AND (
                  (o.opportunity_type = 'sisu'   AND o.year = 2025) OR
                  (o.opportunity_type = 'prouni' AND o.year = 2025)
              )
              AND public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) <= 500
            ORDER BY o.cutoff_score DESC NULLS LAST
            LIMIT 3000
        ) path_b

        UNION ALL

        -- Path C: no filters, no location → random sample
        SELECT * FROM (
            SELECT
                o.id AS opp_id,
                'mec_' || o.id::text AS unified_id,
                o.course_id,
                c.course_name,
                o.opportunity_type,
                o.scholarship_type,
                o.concurrency_type,
                o.cutoff_score,
                o.shift,
                false AS is_partner,
                cp.latitude  AS campus_lat,
                cp.longitude AS campus_lon,
                cp.state     AS campus_state,
                cp.city      AS campus_city,
                i.id         AS institution_id,
                sv.peso_linguagens,
                sv.peso_ciencias_humanas,
                sv.peso_ciencias_natureza,
                sv.peso_matematica,
                sv.peso_redacao,
                sv.vagas_ociosas_2025,
                NULL::jsonb  AS eligibility_criteria
            FROM public.opportunities o
            JOIN public.courses c       ON c.id = o.course_id
            JOIN public.campus cp       ON cp.id = c.campus_id
            JOIN public.institutions i  ON i.id = cp.institution_id
            LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
            WHERE NOT v_has_funnel_filters
              AND (v_lat IS NULL OR v_lon IS NULL)
              AND o.semester = '1'
              AND (
                  (o.opportunity_type = 'sisu'   AND o.year = 2025) OR
                  (o.opportunity_type = 'prouni' AND o.year = 2025)
              )
            ORDER BY RANDOM()
            LIMIT 2000
        ) path_c
    ),

    -- ── Partners: always ALL approved ────────────────────────────────────────
    all_opportunities AS (
        SELECT * FROM mec_funnel

        UNION ALL

        SELECT
            po.id         AS opp_id,
            'partner_' || po.id::text AS unified_id,
            NULL::uuid    AS course_id,
            po.name       AS course_name,
            'partner'     AS opportunity_type,
            NULL          AS scholarship_type,
            NULL          AS concurrency_type,
            NULL::numeric AS cutoff_score,
            NULL          AS shift,
            true          AS is_partner,
            NULL::numeric AS campus_lat,
            NULL::numeric AS campus_lon,
            NULL          AS campus_state,
            NULL          AS campus_city,
            po.institution_id,
            NULL          AS peso_linguagens,
            NULL          AS peso_ciencias_humanas,
            NULL          AS peso_ciencias_natureza,
            NULL          AS peso_matematica,
            NULL          AS peso_redacao,
            NULL::integer AS vagas_ociosas_2025,
            po.eligibility_criteria
        FROM public.partner_opportunities po
        WHERE po.status::text IN ('approved', 'incoming', 'opened', 'closed')
    ),

    -- ── Pilar 1: Performance & Elegibilidade (40%) ───────────────────────────
    scored_performance AS (
        SELECT
            ao.*,
            CASE
                WHEN ao.opportunity_type = 'prouni'
                     AND ao.scholarship_type ILIKE '%Integral%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5
                THEN false
                WHEN ao.opportunity_type = 'prouni'
                     AND ao.scholarship_type ILIKE '%Parcial%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 3.0
                THEN false
                WHEN ao.opportunity_type = 'sisu'
                     AND ao.concurrency_type ILIKE '%renda%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5
                THEN false
                WHEN ao.is_partner
                     AND ao.eligibility_criteria->>'per_capita_income_limit' IS NOT NULL
                     AND v_income IS NOT NULL
                     AND v_income > (ao.eligibility_criteria->>'per_capita_income_limit')::numeric
                THEN false
                ELSE true
            END AS meets_income,
            CASE
                WHEN v_has_enem AND ao.peso_linguagens IS NOT NULL THEN
                    (
                        COALESCE(v_nota_linguagens, 0)        * COALESCE(ao.peso_linguagens::numeric, 1) +
                        COALESCE(v_nota_ciencias_humanas, 0)  * COALESCE(ao.peso_ciencias_humanas::numeric, 1) +
                        COALESCE(v_nota_ciencias_natureza, 0) * COALESCE(ao.peso_ciencias_natureza::numeric, 1) +
                        COALESCE(v_nota_matematica, 0)        * COALESCE(ao.peso_matematica::numeric, 1) +
                        COALESCE(v_nota_redacao, 0)           * COALESCE(ao.peso_redacao::numeric, 1)
                    ) / NULLIF(
                        COALESCE(ao.peso_linguagens::numeric, 1) +
                        COALESCE(ao.peso_ciencias_humanas::numeric, 1) +
                        COALESCE(ao.peso_ciencias_natureza::numeric, 1) +
                        COALESCE(ao.peso_matematica::numeric, 1) +
                        COALESCE(ao.peso_redacao::numeric, 1),
                        0
                    )
                WHEN v_has_enem THEN v_enem_avg
                ELSE NULL
            END AS weighted_enem_score
        FROM all_opportunities ao
    ),

    scored_academic AS (
        SELECT
            sp.*,
            CASE
                WHEN sp.weighted_enem_score IS NOT NULL AND sp.cutoff_score IS NOT NULL AND sp.cutoff_score > 0 THEN
                    GREATEST(0.0, LEAST(100.0,
                        100.0 - GREATEST(0.0, sp.cutoff_score - sp.weighted_enem_score) * 0.5
                    ))
                WHEN sp.weighted_enem_score IS NOT NULL THEN
                    LEAST(100.0, (sp.weighted_enem_score / 700.0) * 100.0)
                ELSE 50.0
            END AS academic_score
        FROM scored_performance sp
    ),

    -- ── Pilar 2: Preferências (30%) ──────────────────────────────────────────
    scored_preferences AS (
        SELECT
            sa.*,
            CASE
                WHEN v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0 THEN 50.0
                WHEN sa.shift IS NULL THEN 50.0
                WHEN sa.shift = ANY(v_preferred_shifts) THEN 100.0
                ELSE 0.0
            END AS shift_score,
            CASE
                WHEN v_university_preference IS NULL OR v_university_preference = 'indiferente' THEN 50.0
                WHEN v_university_preference = 'publica'  AND sa.opportunity_type = 'sisu'              THEN 100.0
                WHEN v_university_preference = 'privada'  AND sa.opportunity_type IN ('prouni','partner') THEN 100.0
                ELSE 20.0
            END +
            CASE
                WHEN v_program_preference IS NULL OR v_program_preference = 'indiferente' THEN 50.0
                WHEN v_program_preference = 'sisu'   AND sa.opportunity_type = 'sisu'   THEN 100.0
                WHEN v_program_preference = 'prouni' AND sa.opportunity_type = 'prouni' THEN 100.0
                ELSE 20.0
            END AS inst_program_score_raw,
            CASE
                WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 50.0
                WHEN EXISTS (
                    SELECT 1 FROM unnest(v_course_interests) ci
                    WHERE sa.course_name ILIKE '%' || ci || '%'
                ) THEN 100.0
                ELSE 10.0
            END AS course_score
        FROM scored_academic sa
    ),

    -- ── Pilar 3: Localização (20%) ───────────────────────────────────────────
    scored_location AS (
        SELECT
            sp.*,
            LEAST(100.0, sp.inst_program_score_raw / 2.0) AS inst_program_score,
            CASE
                WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL
                     AND sp.campus_lat IS NOT NULL AND sp.campus_lon IS NOT NULL THEN
                    GREATEST(0.0, 100.0 - public.haversine_km(v_lat, v_lon, sp.campus_lat, sp.campus_lon) * 0.5)
                ELSE 40.0
            END AS distance_score,
            CASE
                WHEN v_state_preference IS NOT NULL AND sp.campus_state IS NOT NULL
                     AND LOWER(sp.campus_state) = LOWER(v_state_preference) THEN 30.0
                WHEN v_location_preference IS NOT NULL AND sp.campus_city IS NOT NULL
                     AND LOWER(sp.campus_city) ILIKE '%' || LOWER(v_location_preference) || '%' THEN 30.0
                ELSE 0.0
            END AS regional_bonus
        FROM scored_preferences sp
    ),

    -- ── Composite score ───────────────────────────────────────────────────────
    composite AS (
        SELECT
            sl.unified_id,
            sl.course_id,
            sl.is_partner,
            sl.meets_income,
            sl.academic_score,
            sl.shift_score,
            sl.inst_program_score,
            sl.course_score,
            sl.distance_score,
            sl.regional_bonus,
            sl.weighted_enem_score,
            sl.cutoff_score,
            sl.vagas_ociosas_2025,
            sl.opportunity_type,
            CASE WHEN sl.meets_income THEN
                LEAST(100.0, GREATEST(0.0,
                    COALESCE((v_weights->>'performance_weight')::NUMERIC, 0.40) * sl.academic_score
                    + COALESCE((v_weights->>'preference_weight')::NUMERIC, 0.30) * (
                        (sl.shift_score * 0.333) + (sl.inst_program_score * 0.333) + (sl.course_score * 0.334)
                    )
                    + COALESCE((v_weights->>'location_weight')::NUMERIC, 0.20) * (
                        LEAST(100.0, sl.distance_score + sl.regional_bonus)
                    )
                ))
            ELSE 0.0
            END AS base_score
        FROM scored_location sl
    ),

    -- ── Pilar 4: Boosts ───────────────────────────────────────────────────────
    boosted AS (
        SELECT
            c.unified_id,
            c.course_id,
            c.is_partner,
            c.meets_income,
            c.opportunity_type,
            c.academic_score,
            c.weighted_enem_score,
            c.cutoff_score,
            c.shift_score,
            c.inst_program_score,
            c.course_score,
            c.distance_score,
            c.regional_bonus,
            c.vagas_ociosas_2025,
            CASE
                WHEN NOT c.meets_income THEN 0.0
                WHEN c.is_partner THEN
                    LEAST(
                        c.base_score * COALESCE((v_weights->>'partner_boost')::NUMERIC, 1.15),
                        c.base_score + COALESCE((v_weights->>'partner_boost_cap')::NUMERIC, 20.0)
                    )
                ELSE c.base_score
            END
            + CASE
                WHEN c.vagas_ociosas_2025 IS NOT NULL AND c.vagas_ociosas_2025 > 0 AND c.meets_income THEN
                    LEAST(COALESCE((v_weights->>'idle_vacancy_boost')::NUMERIC, 5.0),
                          c.vagas_ociosas_2025::NUMERIC * 0.5)
                ELSE 0.0
            END AS final_score,
            jsonb_build_object(
                'meets_income',               c.meets_income,
                'academic_score',             round(c.academic_score, 2),
                'weighted_enem_score',        round(COALESCE(c.weighted_enem_score, 0), 2),
                'cutoff_score',               COALESCE(c.cutoff_score, 0),
                'shift_score',                round(c.shift_score, 2),
                'inst_program_score',         round(c.inst_program_score, 2),
                'course_score',               round(c.course_score, 2),
                'distance_score',             round(c.distance_score, 2),
                'regional_bonus',             round(c.regional_bonus, 2),
                'base_score',                 round(c.base_score, 2),
                'is_partner',                 c.is_partner,
                'boost_applied',              c.is_partner AND c.meets_income,
                'idle_vacancy_boost_applied', (c.vagas_ociosas_2025 IS NOT NULL AND c.vagas_ociosas_2025 > 0),
                'opportunity_type',           c.opportunity_type
            ) AS details
        FROM composite c
    ),

    -- ── MAX score per course ──────────────────────────────────────────────────
    course_best AS (
        SELECT DISTINCT ON (COALESCE(b.course_id::text, b.unified_id))
            b.unified_id,
            b.is_partner,
            LEAST(100.0, round(b.final_score, 2)) AS final_score,
            b.details
        FROM boosted b
        ORDER BY COALESCE(b.course_id::text, b.unified_id), b.final_score DESC
    ),

    -- ── TOP 100 MEC ──────────────────────────────────────────────────────────
    mec_top100 AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best
        WHERE NOT is_partner
        ORDER BY final_score DESC
        LIMIT 100
    ),

    -- ── ALL partners ─────────────────────────────────────────────────────────
    partners_all AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best
        WHERE is_partner
    )

    -- Single SELECT feeds the INSERT
    SELECT p_profile_id, unified_id, final_score, details FROM mec_top100
    UNION ALL
    SELECT p_profile_id, unified_id, final_score, details FROM partners_all;

END;
$$;

COMMENT ON FUNCTION public.calculate_match IS 'V3 Funnel+Cap: Fix Sisu year to 2025, fix po.status values.';

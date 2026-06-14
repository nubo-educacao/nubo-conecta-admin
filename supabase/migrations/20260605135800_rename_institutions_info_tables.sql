-- Rename tables to snake_case and recreate dependent views and functions
-- 20260605135800_rename_institutions_info_tables.sql

-- 1. Drop dependent views/functions
DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog CASCADE;
DROP VIEW IF EXISTS public.v_unified_institutions CASCADE;
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

DROP TABLE IF EXISTS public.institutions_info_sisu CASCADE;
DROP TABLE IF EXISTS public.institutions_info_emec CASCADE;

-- 2. Rename Tables and Indexes
ALTER TABLE IF EXISTS public.institutionsinfosisu RENAME TO institutions_info_sisu;
ALTER INDEX IF EXISTS institutionsinfosisu_pkey RENAME TO institutions_info_sisu_pkey;

ALTER TABLE IF EXISTS public.institutionsinfoemec RENAME TO institutions_info_emec;
ALTER INDEX IF EXISTS institutionsinfoemec_pkey RENAME TO institutions_info_emec_pkey;

-- 3. Recreate v_unified_opportunities
CREATE MATERIALIZED VIEW public.v_unified_opportunities AS
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
    sisu_branch.qt_inscricao_prev,
    sisu_branch.vagas_ociosas_prev,
    sisu_branch.institution_id,
    sisu_branch.institution_igc,
    sisu_branch.institution_organization,
    sisu_branch.institution_category,
    sisu_branch.institution_site,
    sisu_branch.eligibility_criteria,
    sisu_branch.benefits,
    sisu_branch.brand_color,
    sisu_branch.weights,
    sisu_branch.institution_acronym,
    sisu_branch.latitude,
    sisu_branch.longitude
   FROM ( SELECT DISTINCT ON (c.id) ('mec_'::text || (c.id)::text) AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'sisu'::text AS type,
            'sisu'::text AS opportunity_type,
            'public_universities'::text AS category,
            false AS is_partner,
            ((cp.city || ', '::text) || cp.state) AS location,
            (jsonb_build_array(o.shift) - 'null'::text) AS badges,
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
            sv.qt_inscricao_prev,
            sv.vagas_ociosas_prev,
            i.id AS institution_id,
            ie.igc AS institution_igc,
            ie.academic_organization AS institution_organization,
            ie.administrative_category AS institution_category,
            ie.site AS institution_site,
            NULL::jsonb AS eligibility_criteria,
            NULL::jsonb AS benefits,
            NULL::text AS brand_color,
            jsonb_build_object('redacao', sv.peso_redacao, 'matematica', sv.peso_matematica, 'linguagens', sv.peso_linguagens, 'humanas', sv.peso_ciencias_humanas, 'natureza', sv.peso_ciencias_natureza) AS weights,
            sis.acronym AS institution_acronym,
            cp.latitude,
            cp.longitude
           FROM (((((((((public.opportunities o
             JOIN public.programs p ON (((p.type = 'sisu'::text) AND (p.status = ANY (ARRAY['incoming'::text, 'opened'::text])))))
             JOIN public.courses c ON ((c.id = o.course_id)))
             JOIN public.campus cp ON ((cp.id = c.campus_id)))
             JOIN public.institutions i ON ((i.id = cp.institution_id)))
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM public.opportunities
                  WHERE (opportunities.opportunity_type = 'sisu'::text)
                  GROUP BY opportunities.course_id) s ON ((s.course_id = o.course_id)))
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM public.important_dates d
                  WHERE ((d.type = 'sisu'::text) AND (d.controls_opportunity_dates = true))
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON (true))
             LEFT JOIN public.opportunities_sisu_vacancies sv ON ((sv.opportunity_id = o.id)))
             LEFT JOIN public.institutions_info_emec ie ON ((ie.institution_id = i.id)))
             LEFT JOIN public.institutions_info_sisu sis ON ((sis.institution_id = i.id)))
          WHERE ((o.opportunity_type = 'sisu'::text) AND (o.year = p.cycle_year) AND (o.semester = p.cycle_semester))
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
    prouni_branch.qt_inscricao_prev,
    prouni_branch.vagas_ociosas_prev,
    prouni_branch.institution_id,
    prouni_branch.institution_igc,
    prouni_branch.institution_organization,
    prouni_branch.institution_category,
    prouni_branch.institution_site,
    prouni_branch.eligibility_criteria,
    prouni_branch.benefits,
    prouni_branch.brand_color,
    prouni_branch.weights,
    prouni_branch.institution_acronym,
    prouni_branch.latitude,
    prouni_branch.longitude
   FROM ( SELECT DISTINCT ON (c.id) ('mec_'::text || (c.id)::text) AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'prouni'::text AS type,
            'prouni'::text AS opportunity_type,
            'grants_scholarships'::text AS category,
            false AS is_partner,
            ((cp.city || ', '::text) || cp.state) AS location,
            (jsonb_build_array('100% Gratuito', o.shift) - 'null'::text) AS badges,
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
            NULL::text AS qt_inscricao_prev,
            pv_agg.vagas_ociosas_prev,
            i.id AS institution_id,
            ie.igc AS institution_igc,
            ie.academic_organization AS institution_organization,
            ie.administrative_category AS institution_category,
            ie.site AS institution_site,
            NULL::jsonb AS eligibility_criteria,
            NULL::jsonb AS benefits,
            NULL::text AS brand_color,
            NULL::jsonb AS weights,
            sis.acronym AS institution_acronym,
            cp.latitude,
            cp.longitude
           FROM (((((((((public.opportunities o
             JOIN public.programs p ON (((p.type = 'prouni'::text) AND (p.status = ANY (ARRAY['incoming'::text, 'opened'::text])))))
             JOIN public.courses c ON ((c.id = o.course_id)))
             JOIN public.campus cp ON ((cp.id = c.campus_id)))
             JOIN public.institutions i ON ((i.id = cp.institution_id)))
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM public.opportunities
                  WHERE (opportunities.opportunity_type = 'prouni'::text)
                  GROUP BY opportunities.course_id) s ON ((s.course_id = o.course_id)))
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM public.important_dates d
                  WHERE ((d.type = 'prouni'::text) AND (d.controls_opportunity_dates = true))
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON (true))
             LEFT JOIN LATERAL ( SELECT (sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)))::text AS qt_vagas_ofertadas,
                    (sum(((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada))))::integer AS vagas_ociosas_prev
                   FROM public.opportunities_prouni_vacancies pv
                  WHERE (pv.opportunity_id = o.id)) pv_agg ON (true))
             LEFT JOIN public.institutions_info_emec ie ON ((ie.institution_id = i.id)))
             LEFT JOIN public.institutions_info_sisu sis ON ((sis.institution_id = i.id)))
          WHERE ((o.opportunity_type = 'prouni'::text) AND (o.year = p.cycle_year) AND (o.semester = p.cycle_semester))
          ORDER BY c.id, o.created_at) prouni_branch
UNION ALL
 SELECT ('partner_'::text || (po.id)::text) AS unified_id,
    po.name AS title,
    i.name AS provider_name,
    'partner'::text AS type,
    po.opportunity_type,
    'educational_programs'::text AS category,
    true AS is_partner,
    'Nacional'::text AS location,
    COALESCE((po.eligibility_criteria -> 'badges'::text), '[]'::jsonb) AS badges,
    po.created_at,
    (po.external_redirect_config ->> 'url'::text) AS external_redirect_url,
    COALESCE(((po.external_redirect_config ->> 'enabled'::text))::boolean, false) AS external_redirect_enabled,
    (po.status)::text AS status,
    po.starts_at,
    po.ends_at,
    NULL::numeric AS match_score,
    NULL::numeric AS min_cutoff_score,
    NULL::numeric AS max_cutoff_score,
    pi.cover_url AS institution_cover_url,
    NULL::text AS nu_vagas_autorizadas,
    NULL::text AS qt_vagas_ofertadas,
    NULL::text AS qt_inscricao_prev,
    NULL::integer AS vagas_ociosas_prev,
    i.id AS institution_id,
    ie.igc AS institution_igc,
    ie.academic_organization AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site AS institution_site,
    po.eligibility_criteria,
    NULL::jsonb AS benefits,
    pi.brand_color,
    NULL::jsonb AS weights,
    sis.acronym AS institution_acronym,
    NULL::double precision AS latitude,
    NULL::double precision AS longitude
   FROM ((((public.partner_opportunities po
     JOIN public.institutions i ON ((i.id = po.institution_id)))
     LEFT JOIN public.partner_institutions pi ON ((pi.institution_id = i.id)))
     LEFT JOIN public.institutions_info_emec ie ON ((ie.institution_id = i.id)))
     LEFT JOIN public.institutions_info_sisu sis ON ((sis.institution_id = i.id)))
  WHERE ((po.status)::text = ANY (ARRAY['incoming'::text, 'opened'::text, 'closed'::text]));

CREATE UNIQUE INDEX IF NOT EXISTS v_unified_opportunities_unified_id_idx ON public.v_unified_opportunities (unified_id);

-- 4. Recreate v_unified_institutions
CREATE OR REPLACE VIEW public.v_unified_institutions AS
 WITH inst_opps AS (
         SELECT v_unified_opportunities.institution_id,
            array_agg(DISTINCT v_unified_opportunities.opportunity_type) AS opp_types
           FROM public.v_unified_opportunities
          GROUP BY v_unified_opportunities.institution_id
        )
 SELECT i.id,
    i.name,
    COALESCE(pi.location,
        CASE
            WHEN ((ie.city IS NOT NULL) AND (ie.state IS NOT NULL)) THEN ((ie.city || ' - '::text) || ie.state)
            WHEN (ie.city IS NOT NULL) THEN ie.city
            WHEN (ie.state IS NOT NULL) THEN ie.state
            ELSE ( SELECT ((c.city || ' - '::text) || c.state)
               FROM public.campus c
              WHERE ((c.institution_id = i.id) AND (c.city IS NOT NULL))
             LIMIT 1)
        END) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    pi.website_url,
    sisu.acronym,
        CASE
            WHEN (i.is_partner IS TRUE) THEN 'partner'::text
            ELSE 'mec'::text
        END AS type,
    io.opp_types,
    COALESCE(sisu.academic_organization, ie.academic_organization) AS academic_organization,
    COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category
   FROM ((((public.institutions i
     LEFT JOIN public.partner_institutions pi ON ((pi.institution_id = i.id)))
     LEFT JOIN public.institutions_info_emec ie ON ((ie.institution_id = i.id)))
     LEFT JOIN public.institutions_info_sisu sisu ON ((sisu.institution_id = i.id)))
     LEFT JOIN inst_opps io ON ((io.institution_id = i.id)));

-- 5. Recreate mv_course_catalog
CREATE MATERIALIZED VIEW public.mv_course_catalog AS
 WITH opportunity_aggregates AS (
         SELECT o.course_id,
            min(o.cutoff_score) AS min_cutoff,
            max(o.cutoff_score) AS max_cutoff,
            bool_or((o.opportunity_type = 'sisu'::text)) AS has_sisu,
            bool_or((o.opportunity_type = 'prouni'::text)) AS has_prouni,
            bool_or(((o.shift ~~* '%EAD%'::text) OR (o.shift ~~* '%distância%'::text))) AS has_ead,
            bool_or(((o.is_nubo_pick = true) OR (COALESCE(osv.vagas_ociosas_prev, 0) > 0))) AS has_nubo_pick,
            bool_or((EXISTS ( SELECT 1
                   FROM jsonb_array_elements(o.concurrency_tags) tags_group(value)
                  WHERE (EXISTS ( SELECT 1
                           FROM jsonb_array_elements_text(tags_group.value) tag(value)
                          WHERE (tag.value <> ALL (ARRAY['AMPLA_CONCORRENCIA'::text, 'MILITAR'::text, 'OUTROS'::text, 'BOLSA_PARCIAL'::text, 'BOLSA_INTEGRAL'::text]))))))) AS has_affirmative_action_tags,
            json_agg(json_build_object('id', o.id, 'shift', o.shift, 'scholarship_type', o.scholarship_type, 'concurrency_type', o.concurrency_type, 'concurrency_tags', o.concurrency_tags, 'scholarship_tags', o.scholarship_tags, 'opportunity_type', o.opportunity_type, 'cutoff_score', o.cutoff_score, 'is_nubo_pick', ((o.is_nubo_pick = true) OR (COALESCE(osv.vagas_ociosas_prev, 0) > 0)))) AS opportunities_json
           FROM ((public.opportunities o
             JOIN public.programs p ON (((p.type = o.opportunity_type) AND (p.status = ANY (ARRAY['incoming'::text, 'opened'::text])))))
             LEFT JOIN public.opportunities_sisu_vacancies osv ON ((osv.opportunity_id = o.id)))
          WHERE ((o.year = p.cycle_year) AND (o.semester = p.cycle_semester) AND ((o.opportunity_type <> 'sisu'::text) OR (osv.qt_vagas_ofertadas IS NULL) OR ((replace(replace(TRIM(BOTH FROM osv.qt_vagas_ofertadas), '.'::text, ''::text), ','::text, '.'::text))::numeric > (0)::numeric)))
          GROUP BY o.course_id
        )
 SELECT c.id AS course_id,
    c.course_name,
    i.name AS institution_name,
    cp.city,
    cp.state,
    cp.latitude,
    cp.longitude,
    c.vacancies AS vacancies_json,
    COALESCE(em.igc, '0'::text) AS igc_raw,
        CASE
            WHEN (em.igc = ANY (ARRAY['1'::text, '2'::text, '3'::text, '4'::text, '5'::text])) THEN (em.igc)::numeric
            ELSE (0)::numeric
        END AS igc_value,
    oa.min_cutoff,
    oa.max_cutoff,
    COALESCE(oa.has_sisu, false) AS has_sisu,
    COALESCE(oa.has_prouni, false) AS has_prouni,
    COALESCE(oa.has_ead, false) AS has_ead,
    COALESCE(oa.has_nubo_pick, false) AS has_nubo_pick,
    (COALESCE(oa.has_affirmative_action_tags, false) OR (( SELECT COALESCE(sum(((elem.value ->> 'quotas_offered'::text))::numeric), (0)::numeric) AS "coalesce"
           FROM jsonb_array_elements(c.vacancies) elem(value)) > (1)::numeric)) AS has_affirmative_action,
    COALESCE(oa.opportunities_json, '[]'::json) AS opportunities_json,
    to_tsvector('portuguese'::regconfig, ((((unaccent(c.course_name) || ' '::text) || unaccent(i.name)) || ' '::text) || unaccent(cp.city))) AS search_vector
   FROM ((((public.courses c
     JOIN public.campus cp ON ((c.campus_id = cp.id)))
     JOIN public.institutions i ON ((cp.institution_id = i.id)))
     LEFT JOIN public.institutions_info_emec em ON ((i.id = em.institution_id)))
     JOIN opportunity_aggregates oa ON ((c.id = oa.course_id)));

CREATE INDEX IF NOT EXISTS mv_course_catalog_search_idx ON public.mv_course_catalog USING gin(search_vector);
CREATE UNIQUE INDEX IF NOT EXISTS mv_course_catalog_course_id_idx ON public.mv_course_catalog (course_id);

-- 6. Recreate get_unified_opportunities_by_distance
CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(p_lat double precision, p_long double precision)
 RETURNS TABLE(unified_id text, title text, provider_name text, type text, opportunity_type text, category text, is_partner boolean, location text, badges jsonb, created_at timestamp with time zone, external_redirect_url text, external_redirect_enabled boolean, status text, starts_at timestamp with time zone, ends_at timestamp with time zone, match_score numeric, min_cutoff_score numeric, max_cutoff_score numeric, institution_cover_url text, nu_vagas_autorizadas text, qt_vagas_ofertadas text, qt_inscricao_prev text, vagas_ociosas_prev integer, institution_id uuid, institution_igc text, institution_organization text, institution_category text, institution_site text, eligibility_criteria jsonb, benefits jsonb, brand_color text, weights jsonb, institution_acronym text, latitude double precision, longitude double precision, distance_km numeric)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT 
    v.unified_id,
    v.title,
    v.provider_name,
    v.type,
    v.opportunity_type,
    v.category,
    v.is_partner,
    v.location,
    v.badges,
    v.created_at,
    v.external_redirect_url,
    v.external_redirect_enabled,
    v.status,
    v.starts_at,
    v.ends_at,
    v.match_score,
    v.min_cutoff_score,
    v.max_cutoff_score,
    v.institution_cover_url,
    v.nu_vagas_autorizadas,
    v.qt_vagas_ofertadas,
    v.qt_inscricao_prev,
    v.vagas_ociosas_prev,
    v.institution_id,
    v.institution_igc,
    v.institution_organization,
    v.institution_category,
    v.institution_site,
    v.eligibility_criteria,
    v.benefits,
    v.brand_color,
    v.weights,
    v.institution_acronym,
    v.latitude,
    v.longitude,
    CASE 
      WHEN v.latitude IS NULL OR v.longitude IS NULL THEN 0
      WHEN p_lat IS NULL OR p_long IS NULL THEN 0
      ELSE public.haversine_km(p_lat, p_long, v.latitude, v.longitude)
    END AS distance_km
  FROM public.v_unified_opportunities v
$function$;

-- 7. Recreate etl_import_emec
CREATE OR REPLACE FUNCTION public.etl_import_emec()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '10min'
AS $function$
DECLARE
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_inst_id           UUID;
BEGIN
  -- Start log
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (null, 'emec', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT DISTINCT ON ("Código IES")
      "Código IES"::text AS inst_external_code,
      "Código Mantenedora" AS maintainer_code,
      "Razão Social" AS maintainer_name,
      "CNPJ",
      "Natureza Jurídica" AS legal_nature,
      "Telefone" AS phone,
      "Sitio" AS site,
      "e-Mail" AS email,
      "Endereço Sede" AS address_seat,
      "Município" AS city,
      "UF" AS state,
      "Organização Acadêmica" AS academic_organization,
      "Tipo de Credenciamento" AS credentialing_type,
      "Categoria Administrativa" AS administrative_category,
      "Data do Ato de Criação da IES" AS creation_date_str,
      "CI",
      "Ano CI" AS ci_year,
      "CI-EaD",
      "Ano CI-EaD" AS ci_ead_year,
      "IGC",
      "Ano IGC" AS igc_year,
      "Reitor/Dirigente Principal" AS rector,
      "Representante Legal" AS legal_representative,
      "Sinalizações Vigentes" AS current_signs,
      "Situação da IES" AS status
    FROM public.rawemec
    WHERE "Código IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;

      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_emec (
          institution_id, maintainer_code, maintainer_name, cnpj, legal_nature, phone, site, email,
          address_seat, city, state, academic_organization, credentialing_type, administrative_category,
          creation_date, ci, ci_year, ci_ead, ci_ead_year, igc, igc_year, rector, legal_representative,
          current_signs, status
        )
        VALUES (
          v_inst_id,
          v_rec.maintainer_code,
          v_rec.maintainer_name,
          v_rec.cnpj,
          v_rec.legal_nature,
          v_rec.phone,
          v_rec.site,
          v_rec.email,
          v_rec.address_seat,
          v_rec.city,
          v_rec.state,
          v_rec.academic_organization,
          v_rec.credentialing_type,
          v_rec.administrative_category,
          CASE WHEN v_rec.creation_date_str ~ '^\d{4}-\d{2}-\d{2}$' THEN v_rec.creation_date_str::DATE ELSE NULL END,
          v_rec."CI",
          v_rec.ci_year,
          v_rec."CI-EaD",
          v_rec.ci_ead_year,
          v_rec."IGC",
          v_rec.igc_year,
          v_rec.rector,
          v_rec.legal_representative,
          v_rec.current_signs,
          v_rec.status
        )
        ON CONFLICT (institution_id)
        DO UPDATE SET
          maintainer_code = EXCLUDED.maintainer_code,
          maintainer_name = EXCLUDED.maintainer_name,
          cnpj = EXCLUDED.cnpj,
          legal_nature = EXCLUDED.legal_nature,
          phone = EXCLUDED.phone,
          site = EXCLUDED.site,
          email = EXCLUDED.email,
          address_seat = EXCLUDED.address_seat,
          city = EXCLUDED.city,
          state = EXCLUDED.state,
          academic_organization = EXCLUDED.academic_organization,
          credentialing_type = EXCLUDED.credentialing_type,
          administrative_category = EXCLUDED.administrative_category,
          creation_date = EXCLUDED.creation_date,
          ci = EXCLUDED.ci,
          ci_year = EXCLUDED.ci_year,
          ci_ead = EXCLUDED.ci_ead,
          ci_ead_year = EXCLUDED.ci_ead_year,
          igc = EXCLUDED.igc,
          igc_year = EXCLUDED.igc_year,
          rector = EXCLUDED.rector,
          legal_representative = EXCLUDED.legal_representative,
          current_signs = EXCLUDED.current_signs,
          status = EXCLUDED.status,
          updated_at = now();

        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- Update log
  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$function$;

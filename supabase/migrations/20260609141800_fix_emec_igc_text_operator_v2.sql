-- 20260609141500_fix_emec_igc_text_operator.sql

CREATE OR REPLACE FUNCTION public.etl_import_emec(
  p_limit integer DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_log_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_log_id              UUID;
  v_processed           INTEGER := 0;
  v_errors              TEXT;
  v_rec                 RECORD;
  v_inst_id             UUID;
  v_raw_count           INTEGER;
  v_unmatched           INTEGER;
  v_emec_total          INTEGER;
  v_with_igc            INTEGER;
  v_with_ci             INTEGER;
  v_federal             INTEGER;
  v_estadual            INTEGER;
  v_privado             INTEGER;
  v_detail_msg          TEXT;
  v_has_more            BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT COUNT(DISTINCT "Código IES") INTO v_raw_count FROM public.rawemec WHERE "Código IES" IS NOT NULL;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (null, 'emec', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  FOR v_rec IN
    SELECT DISTINCT ON ("Código IES")
      "Código IES"::text AS inst_external_code, "Código Mantenedora" AS maintainer_code, "Razão Social" AS maintainer_name, "CNPJ" AS cnpj, "Natureza Jurídica" AS legal_nature, "Telefone" AS phone, "Sitio" AS site, "e-Mail" AS email, "Endereço Sede" AS address_seat, "Município" AS city, "UF" AS state, "Organização Acadêmica" AS academic_organization, "Tipo de Credenciamento" AS credentialing_type, "Categoria Administrativa" AS administrative_category, "Data do Ato de Criação da IES" AS creation_date_str, "CI" AS ci, "Ano CI" AS ci_year, "CI-EaD" AS ci_ead, "Ano CI-EaD" AS ci_ead_year, "IGC" AS igc, "Ano IGC" AS igc_year, "Reitor/Dirigente Principal" AS rector, "Representante Legal" AS legal_representative, "Sinalizações Vigentes" AS current_signs, "Situação da IES" AS status
    FROM (SELECT * FROM public.rawemec ORDER BY "Código IES" LIMIT p_limit OFFSET p_offset) r
    WHERE "Código IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_emec (institution_id, maintainer_code, maintainer_name, cnpj, legal_nature, phone, site, email, address_seat, city, state, academic_organization, credentialing_type, administrative_category, creation_date, ci, ci_year, ci_ead, ci_ead_year, igc, igc_year, rector, legal_representative, current_signs, status)
        VALUES (v_inst_id, v_rec.maintainer_code, v_rec.maintainer_name, v_rec.cnpj, v_rec.legal_nature, v_rec.phone, v_rec.site, v_rec.email, v_rec.address_seat, v_rec.city, v_rec.state, v_rec.academic_organization, v_rec.credentialing_type, v_rec.administrative_category, CASE WHEN v_rec.creation_date_str ~ '^\d{4}-\d{2}-\d{2}$' THEN v_rec.creation_date_str::DATE ELSE NULL END, v_rec.ci, v_rec.ci_year, v_rec.ci_ead, v_rec.ci_ead_year, v_rec.igc, v_rec.igc_year, v_rec.rector, v_rec.legal_representative, v_rec.current_signs, v_rec.status)
        ON CONFLICT (institution_id) DO UPDATE SET maintainer_code = EXCLUDED.maintainer_code, maintainer_name = EXCLUDED.maintainer_name, cnpj = EXCLUDED.cnpj, legal_nature = EXCLUDED.legal_nature, phone = EXCLUDED.phone, site = EXCLUDED.site, email = EXCLUDED.email, address_seat = EXCLUDED.address_seat, city = EXCLUDED.city, state = EXCLUDED.state, academic_organization = EXCLUDED.academic_organization, credentialing_type = EXCLUDED.credentialing_type, administrative_category = EXCLUDED.administrative_category, creation_date = EXCLUDED.creation_date, ci = EXCLUDED.ci, ci_year = EXCLUDED.ci_year, ci_ead = EXCLUDED.ci_ead, ci_ead_year = EXCLUDED.ci_ead_year, igc = EXCLUDED.igc, igc_year = EXCLUDED.igc_year, rector = EXCLUDED.rector, legal_representative = EXCLUDED.legal_representative, current_signs = EXCLUDED.current_signs, status = EXCLUDED.status, updated_at = now();
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_unmatched := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_emec_total FROM public.institutions_info_emec;
    SELECT COUNT(*) INTO v_with_igc FROM public.institutions_info_emec WHERE igc IS NOT NULL AND igc IN ('1','2','3','4','5');
    SELECT COUNT(*) INTO v_with_ci FROM public.institutions_info_emec WHERE ci IS NOT NULL AND ci IN ('1','2','3','4','5');
    SELECT COUNT(*) INTO v_federal FROM public.institutions_info_emec WHERE UPPER(administrative_category) LIKE '%FEDERAL%';
    SELECT COUNT(*) INTO v_estadual FROM public.institutions_info_emec WHERE UPPER(administrative_category) LIKE '%ESTADUAL%';
    SELECT COUNT(*) INTO v_privado FROM public.institutions_info_emec WHERE UPPER(administrative_category) LIKE '%PRIVAD%';

    IF v_errors IS NULL THEN
      v_detail_msg := 'Metadados e-MEC importados com sucesso.' || chr(10) || '• IES distintas no arquivo:       ' || v_raw_count || chr(10) || '• IES atualizadas (com match):    ' || v_total_processed_in_log || chr(10) || '• IES sem match (não cadastradas):' || v_unmatched || chr(10) || '• Total em institutions_info_emec:' || v_emec_total || chr(10) || '• IES com IGC:                    ' || v_with_igc || chr(10) || '• IES com CI:                     ' || v_with_ci || chr(10) || '• Federais / Estaduais / Privadas: ' || v_federal || ' / ' || v_estadual || ' / ' || v_privado;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      -- rawemec is a permanent reference table (all IES in Brazil) and must NOT be truncated after ETL.
      -- Unlike rawsisu/rawprouni which are per-cycle imports, rawemec is reused whenever new institutions are added.
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;

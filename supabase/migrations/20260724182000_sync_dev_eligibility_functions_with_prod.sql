-- 20260724182000_sync_dev_eligibility_functions_with_prod.sql
--
-- Duas funções no dev ainda referenciam user_profiles.eligibility_results
-- (que está prestes a ser dropada, ver 20260724181500) com uma definição
-- desatualizada em relação a prod:
--
-- 1. get_eligible_count_for_partner: prod já lê de sa.eligibility_results
--    (flat array, campo 'met'), dev ainda lia de up.eligibility_results
--    (formato agrupado por partner_id, campos met_criteria/total_criteria).
-- 2. calculate_passport_eligibility: prod já não escreve mais em
--    user_profiles (só faz RETURN dos resultados), dev ainda tinha o
--    UPDATE public.user_profiles SET eligibility_results = ... no final.
--
-- Ambas reaplicadas aqui com o texto EXATO copiado de prod via
-- pg_get_functiondef, para dev corresponder a prod nesse quesito também.
--
-- calculate_application_eligibility NÃO foi tocada: ela também referencia
-- user_profiles.eligibility_results em prod (função aparentemente obsoleta/
-- não usada por lá, já que a coluna não existe mais) — deixando como está
-- no dev para espelhar fielmente o estado real de prod, e não "consertar"
-- algo que o próprio prod ainda não consertou.
--
-- calculate_passport_eligibility (prod) também depende de
-- partners.applications_open, que não existia no dev — adicionada abaixo
-- (boolean default true, idêntica a prod) para não deixar essa função
-- quebrada por um segundo motivo.

ALTER TABLE public.partners
  ADD COLUMN IF NOT EXISTS applications_open boolean DEFAULT true;

CREATE OR REPLACE FUNCTION public.get_eligible_count_for_partner(p_partner_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
      DECLARE
          v_count BIGINT;
      BEGIN
          SELECT COUNT(DISTINCT sa.user_id) INTO v_count
          FROM public.student_applications sa
          WHERE sa.partner_id = p_partner_id
            AND jsonb_typeof(sa.eligibility_results) = 'array'
            AND jsonb_array_length(sa.eligibility_results) > 0
            AND NOT EXISTS (
               SELECT 1 FROM jsonb_array_elements(sa.eligibility_results) AS elem
               WHERE (elem->>'met')::boolean = false
            );

          RETURN v_count;
      END;
      $function$;

CREATE OR REPLACE FUNCTION public.calculate_passport_eligibility(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      DECLARE
          v_profile_record RECORD;
          v_target_id UUID;
          v_target_profile RECORD;
          v_form_record RECORD;
          v_results JSONB := '[]'::jsonb;
          v_partner_results JSONB := '{}'::jsonb;
          v_value JSONB;
          v_profile_json JSONB;
          v_met BOOLEAN;
          v_partner_id UUID;
          v_partners_record RECORD;
          v_student_answers JSONB;
          v_app_record RECORD;
      BEGIN
          -- 1. Get user profile to find target
          SELECT * INTO v_profile_record FROM public.user_profiles WHERE id = p_user_id;
          IF NOT FOUND THEN
              RETURN jsonb_build_object('status', 'error', 'message', 'User not found');
          END IF;

          -- Explicitly use dependent if current_dependent_id is populated
          IF v_profile_record.current_dependent_id IS NOT NULL THEN
              v_target_id := v_profile_record.current_dependent_id;
          ELSE
              v_target_id := COALESCE(v_profile_record.active_application_target_id, p_user_id);
          END IF;

          SELECT * INTO v_target_profile FROM public.user_profiles WHERE id = v_target_id;
          v_profile_json := to_jsonb(v_target_profile);

          -- 2. Initialize results for ALL OPEN partners
          FOR v_partners_record IN SELECT id, name FROM public.partners WHERE applications_open = TRUE LOOP
              v_partner_results := jsonb_set(v_partner_results, ARRAY[v_partners_record.id::text],
                  jsonb_build_object(
                      'partner_id', v_partners_record.id,
                      'partner_name', v_partners_record.name,
                      'total_criteria', 0,
                      'met_criteria', 0,
                      'details', '[]'::jsonb
                  )
              );
          END LOOP;

          -- 3. Calculate criteria from partner_forms
          FOR v_form_record IN
              SELECT pf.partner_id, pf.field_name, pf.mapping_source, pf.criterion_rule
              FROM public.partner_forms pf
              JOIN public.partners p ON p.id = pf.partner_id
              WHERE pf.is_criterion = true
              AND p.applications_open = true
          LOOP
              BEGIN
                  v_partner_id := v_form_record.partner_id;
                  v_value := NULL;
                  v_met := false;

                  -- Try to extract value from user profile
                  IF v_form_record.mapping_source IS NOT NULL AND v_form_record.mapping_source LIKE 'user_profiles.%' THEN
                      v_value := v_profile_json -> split_part(v_form_record.mapping_source, '.', 2);
                  END IF;

                  -- If no value from profile mapping, try to get from student_application answers
                  IF (v_value IS NULL OR v_value::text = 'null' OR v_value::text = '""') THEN
                      SELECT answers INTO v_student_answers
                      FROM public.student_applications
                      WHERE user_id = p_user_id
                        AND partner_id = v_partner_id
                        AND status IN ('SUBMITTED', 'IN_PROGRESS')
                      ORDER BY created_at DESC
                      LIMIT 1;

                      IF v_student_answers IS NOT NULL THEN
                          v_value := v_student_answers -> v_form_record.field_name;
                      END IF;
                  END IF;

                  -- Only count if value exists
                  IF v_value IS NOT NULL AND v_value::text <> 'null' AND v_value::text <> '""' THEN
                      v_partner_results := jsonb_set(v_partner_results, ARRAY[v_partner_id::text, 'total_criteria'],
                          to_jsonb((v_partner_results->v_partner_id::text->>'total_criteria')::int + 1));

                      IF v_form_record.criterion_rule IS NULL THEN
                          v_met := true;
                      ELSE
                          BEGIN
                              DECLARE
                                  v_op TEXT := (SELECT key FROM jsonb_each(v_form_record.criterion_rule) LIMIT 1);
                                  v_args JSONB := v_form_record.criterion_rule -> v_op;
                                  v_val1 JSONB;
                                  v_val2 JSONB;
                              BEGIN
                                  IF jsonb_typeof(v_args) = 'array' THEN
                                      v_val1 := v_value;
                                      v_val2 := v_args -> 1;

                                      CASE v_op
                                          WHEN '==' THEN
                                              v_met := (v_val1 = v_val2 OR v_val1::text = v_val2::text);
                                          WHEN 'in' THEN
                                              v_met := (v_val2 @> jsonb_build_array(v_val1) OR v_val2 @> jsonb_build_array(v_val1::text));
                                          WHEN '<' THEN
                                              v_met := (v_val1::text::numeric < v_val2::text::numeric);
                                          WHEN '>' THEN
                                              v_met := (v_val1::text::numeric > v_val2::text::numeric);
                                          WHEN '<=' THEN
                                              v_met := (v_val1::text::numeric <= v_val2::text::numeric);
                                          WHEN '>=' THEN
                                              v_met := (v_val1::text::numeric >= v_val2::text::numeric);
                                          ELSE
                                              v_met := true;
                                      END CASE;
                                  ELSE
                                      v_met := true;
                                  END IF;
                              END;
                          EXCEPTION WHEN OTHERS THEN
                              v_met := false;
                          END;
                      END IF;

                      IF v_met THEN
                          v_partner_results := jsonb_set(v_partner_results, ARRAY[v_partner_id::text, 'met_criteria'],
                              to_jsonb((v_partner_results->v_partner_id::text->>'met_criteria')::int + 1));
                      END IF;

                      v_partner_results := jsonb_set(v_partner_results, ARRAY[v_partner_id::text, 'details'],
                          COALESCE(v_partner_results->v_partner_id::text->'details', '[]'::jsonb) || jsonb_build_object('field', v_form_record.field_name, 'met', v_met));
                  END IF;
              EXCEPTION WHEN OTHERS THEN
                  RAISE NOTICE 'Error processing criterion % for partner %: %', v_form_record.field_name, v_partner_id, SQLERRM;
              END;
          END LOOP;

          -- 4. Convert results object to array
          SELECT jsonb_agg(value) INTO v_results FROM jsonb_each(v_partner_results);
          IF v_results IS NULL THEN v_results := '[]'::jsonb; END IF;

          -- 5. RETURN results DIRECTLY! No update to user_profiles since the column was dropped!
          RETURN v_results;
      END;
      $function$;

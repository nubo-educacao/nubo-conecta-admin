-- update_backfill_to_save_to_applications.sql
-- ===========================================
-- Update backfill RPC to also save eligibility_results to student_applications

CREATE OR REPLACE FUNCTION "public"."backfill_eligibility_and_mappings"()
RETURNS TABLE(
  processed_count integer,
  error_count integer,
  success boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_processed integer := 0;
  v_errors integer := 0;
  v_app record;
  v_field record;
  v_pref_updates jsonb := '{}'::jsonb;
  v_existing_prefs jsonb;
  v_merged_prefs jsonb;
  v_eligibility_results jsonb := '[]'::jsonb;
  v_user_answer text;
  v_met boolean;
  v_col_name text;
  v_json_key text;
BEGIN
  -- Process all submitted/redirected applications
  FOR v_app IN
    SELECT id, user_id, partner_id, answers, status
    FROM public.student_applications
    WHERE status IN ('SUBMITTED', 'redirected')
      AND answers IS NOT NULL
    ORDER BY created_at ASC
  LOOP
    BEGIN
      v_processed := v_processed + 1;
      v_pref_updates := '{}'::jsonb;
      v_eligibility_results := '[]'::jsonb;

      -- For each partner_form field, extract mapping and apply
      FOR v_field IN
        SELECT id, field_name, question_text, mapping_source, is_criterion, criterion_rule
        FROM public.partner_forms
        WHERE partner_id = v_app.partner_id
      LOOP
        v_user_answer := v_app.answers ->> v_field.field_name;

        -- Skip null answers
        IF v_user_answer IS NOT NULL THEN
          -- Map to user_preferences json
          IF v_field.mapping_source LIKE 'user_preferences.%' THEN
            v_json_key := substring(v_field.mapping_source FROM 20);
            v_pref_updates := jsonb_set(v_pref_updates, ARRAY[v_json_key], to_jsonb(v_user_answer));
          END IF;
        END IF;

        -- Calculate eligibility for criterion fields
        IF v_field.is_criterion AND v_field.criterion_rule IS NOT NULL THEN
          v_met := FALSE;
          BEGIN
            v_met := v_user_answer IS NOT NULL;
          EXCEPTION WHEN OTHERS THEN
            v_met := FALSE;
          END;

          v_eligibility_results := v_eligibility_results || jsonb_build_object(
            'question_text', v_field.question_text,
            'met', v_met,
            'user_answer', v_user_answer
          );
        END IF;
      END LOOP;

      -- Update student_applications with eligibility_results
      IF v_eligibility_results != '[]'::jsonb THEN
        UPDATE public.student_applications
        SET eligibility_results = v_eligibility_results
        WHERE id = v_app.id;
      END IF;

      -- Update user_profiles with eligibility_results
      IF v_eligibility_results != '[]'::jsonb THEN
        UPDATE public.user_profiles
        SET eligibility_results = v_eligibility_results
        WHERE id = v_app.user_id;
      END IF;

      -- Also map partner_forms with user_profiles mapping_source
      FOR v_field IN
        SELECT field_name, mapping_source
        FROM public.partner_forms
        WHERE partner_id = v_app.partner_id
          AND mapping_source LIKE 'user_profiles.%'
          AND mapping_source IS NOT NULL
      LOOP
        v_user_answer := v_app.answers ->> v_field.field_name;
        IF v_user_answer IS NOT NULL THEN
          v_col_name := substring(v_field.mapping_source FROM 16);
          -- Dynamic update using CASE statement for known columns
          UPDATE public.user_profiles
          SET
            full_name = CASE WHEN v_col_name = 'full_name' THEN v_user_answer ELSE full_name END,
            phone = CASE WHEN v_col_name = 'phone' THEN v_user_answer ELSE phone END,
            education = CASE WHEN v_col_name = 'education' THEN v_user_answer ELSE education END,
            city = CASE WHEN v_col_name = 'city' THEN v_user_answer ELSE city END,
            state = CASE WHEN v_col_name = 'state' THEN v_user_answer ELSE state END
          WHERE id = v_app.user_id;
        END IF;
      END LOOP;

      -- Update user_preferences if needed
      IF v_pref_updates != '{}'::jsonb THEN
        SELECT preferences INTO v_existing_prefs
        FROM public.user_preferences
        WHERE user_id = v_app.user_id;

        v_merged_prefs := COALESCE(v_existing_prefs, '{}'::jsonb) || v_pref_updates;

        INSERT INTO public.user_preferences (user_id, preferences)
        VALUES (v_app.user_id, v_merged_prefs)
        ON CONFLICT (user_id) DO UPDATE
        SET preferences = v_merged_prefs;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      RAISE WARNING 'Error processing application %: %', v_app.id, SQLERRM;
    END;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_errors, (v_errors = 0);
END;
$function$;




SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "cube" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "earthdistance" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE OR REPLACE FUNCTION "public"."_eligib_eval_leaf"("p_val_text" "text", "p_val_num" numeric, "p_leaf" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    v_op   text;
    v_args jsonb;
    v_lit  jsonb;
BEGIN
    SELECT key INTO v_op FROM jsonb_each(p_leaf) LIMIT 1;
    v_args := p_leaf -> v_op;

    IF v_args IS NULL OR jsonb_typeof(v_args) <> 'array' THEN
        RETURN true;  -- formato inesperado → não bloqueia (fail-open por folha)
    END IF;

    -- literal = elemento que NÃO é o {var}
    v_lit := CASE WHEN (v_args->0) ? 'var' THEN v_args->1 ELSE v_args->0 END;

    CASE v_op
        WHEN '==' THEN
            RETURN lower(btrim(p_val_text)) = lower(btrim(v_lit #>> '{}'));
        WHEN 'in' THEN
            RETURN EXISTS (
                SELECT 1 FROM jsonb_array_elements_text(v_lit) AS opt
                WHERE lower(btrim(opt)) = lower(btrim(p_val_text))
            );
        WHEN '<'  THEN RETURN p_val_num <  public._eligib_to_num(v_lit #>> '{}');
        WHEN '>'  THEN RETURN p_val_num >  public._eligib_to_num(v_lit #>> '{}');
        WHEN '<=' THEN RETURN p_val_num <= public._eligib_to_num(v_lit #>> '{}');
        WHEN '>=' THEN RETURN p_val_num >= public._eligib_to_num(v_lit #>> '{}');
        ELSE
            RETURN true;  -- operador desconhecido → não bloqueia
    END CASE;
EXCEPTION WHEN OTHERS THEN
    RETURN false;  -- erro de cast/comparação → critério não atendido
END;
$$;


ALTER FUNCTION "public"."_eligib_eval_leaf"("p_val_text" "text", "p_val_num" numeric, "p_leaf" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."_eligib_eval_leaf"("p_val_text" "text", "p_val_num" numeric, "p_leaf" "jsonb") IS 'Avalia uma folha JsonLogic (==, in, <, <=, >, >=) de partner_forms contra o valor do usuário.';



CREATE OR REPLACE FUNCTION "public"."_eligib_to_num"("p_text" "text") RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT NULLIF(
        CASE 
            WHEN p_text LIKE '%,%' THEN 
                regexp_replace(
                    replace(replace(btrim(p_text), '.', ''), ',', '.'),
                    '[^0-9.-]', '', 'g'
                )
            ELSE 
                regexp_replace(btrim(p_text), '[^0-9.-]', '', 'g')
        END,
        ''
    )::numeric;
$$;


ALTER FUNCTION "public"."_eligib_to_num"("p_text" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."_eligib_to_num"("p_text" "text") IS 'Extrai numérico de strings sujas usadas em partner_forms.criterion_rule (ex.: "17 anos", "R$ 3.258,21", "4500.00"). Reconhece padrão BR se houver vírgula, e padrão US se houver apenas ponto.';



CREATE OR REPLACE FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text" DEFAULT NULL::"text", "p_last_code" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_first_id UUID; v_last_id UUID;
  v_first_at TIMESTAMPTZ; v_last_at TIMESTAMPTZ;
BEGIN
  -- Só o próprio usuário costura a própria atribuição. Sem isto, qualquer
  -- autenticado poderia reescrever a origem de outra pessoa — e origem é o que
  -- decide a quem o cadastro é creditado.
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'attach_user_attribution: só o próprio usuário pode costurar sua atribuição'
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_first_id FROM public.channel_links WHERE code = p_first_code;
  SELECT id INTO v_last_id  FROM public.channel_links WHERE code = p_last_code;

  -- Retroceder ao histórico de eventos quando o cookie não trouxe os codes:
  -- é o caso de quem clicou, fechou o navegador e voltou depois.
  IF v_first_id IS NULL OR v_last_id IS NULL THEN
    SELECT min(occurred_at), max(occurred_at) INTO v_first_at, v_last_at
      FROM public.engagement_events
     WHERE anonymous_id = p_anonymous_id AND channel_link_id IS NOT NULL;

    IF v_first_id IS NULL THEN
      SELECT channel_link_id INTO v_first_id FROM public.engagement_events
       WHERE anonymous_id = p_anonymous_id AND channel_link_id IS NOT NULL
       ORDER BY occurred_at ASC LIMIT 1;
    END IF;

    IF v_last_id IS NULL THEN
      SELECT channel_link_id INTO v_last_id FROM public.engagement_events
       WHERE anonymous_id = p_anonymous_id AND channel_link_id IS NOT NULL
       ORDER BY occurred_at DESC LIMIT 1;
    END IF;
  END IF;

  IF v_first_id IS NULL AND v_last_id IS NULL THEN
    RETURN jsonb_build_object('status', 'no_attribution');
  END IF;

  -- Os eventos anônimos passam a pertencer à pessoa. Sem isto, o clique que
  -- trouxe o cadastro fica órfão e a taxa de conversão por link nunca fecha.
  UPDATE public.engagement_events
     SET user_id = p_user_id
   WHERE anonymous_id = p_anonymous_id AND user_id IS NULL;

  INSERT INTO public.user_attribution AS ua (
    user_id, first_touch_link_id, last_touch_link_id, first_touch_at, last_touch_at
  ) VALUES (
    p_user_id, v_first_id, v_last_id, coalesce(v_first_at, now()), coalesce(v_last_at, now())
  )
  ON CONFLICT (user_id) DO UPDATE SET
    -- FIRST TOUCH NUNCA É SOBRESCRITO. É o bug do middleware atual, que
    -- reescreve o cookie de referral a cada visita e por isso credita o
    -- cadastro ao último link em vez de a quem de fato trouxe a pessoa.
    last_touch_link_id = coalesce(EXCLUDED.last_touch_link_id, ua.last_touch_link_id),
    last_touch_at      = greatest(coalesce(EXCLUDED.last_touch_at, ua.last_touch_at), ua.last_touch_at),
    updated_at         = now();

  RETURN jsonb_build_object('status', 'ok',
                            'first_touch_link_id', v_first_id,
                            'last_touch_link_id', v_last_id);
END;
$$;


ALTER FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text", "p_last_code" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text", "p_last_code" "text") IS 'Costura os eventos anônimos de um anonymous_id ao usuário recém-autenticado e grava user_attribution. First touch nunca é sobrescrito. TP-7 7B.';



CREATE OR REPLACE FUNCTION "public"."backfill_eligibility_and_mappings"() RETURNS TABLE("processed_count" integer, "error_count" integer, "success" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
  v_income jsonb;
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

      -- ---------------------------------------------------------------------
      -- NOVO: mapping_source com prefixo user_income.%
      -- ---------------------------------------------------------------------
      -- O income_calculator grava o objeto completo na resposta, entao um unico
      -- campo mapeado alimenta todas as colunas de user_income. Respostas em
      -- faixa textual ("Ate 1 salario minimo") NAO sao renda per capita e sao
      -- ignoradas de proposito. Semantica fill-if-null: nunca sobrescreve valor
      -- ja presente em user_income.
      FOR v_field IN
        SELECT field_name, mapping_source
        FROM public.partner_forms
        WHERE partner_id = v_app.partner_id
          AND mapping_source LIKE 'user_income.%'
      LOOP
        v_user_answer := v_app.answers ->> v_field.field_name;

        CONTINUE WHEN v_user_answer IS NULL OR left(btrim(v_user_answer), 1) <> '{';

        BEGIN
          v_income := v_user_answer::jsonb;
        EXCEPTION WHEN OTHERS THEN
          CONTINUE;
        END;

        CONTINUE WHEN v_income ->> 'per_capita_income' IS NULL;

        INSERT INTO public.user_income (
          user_id, family_count, social_benefits, alimony, member_incomes, per_capita_income
        )
        VALUES (
          v_app.user_id,
          NULLIF(v_income ->> 'family_count', '')::integer,
          NULLIF(v_income ->> 'social_benefits', '')::numeric,
          NULLIF(v_income ->> 'alimony', '')::numeric,
          CASE WHEN jsonb_typeof(v_income -> 'member_incomes') = 'array'
               THEN v_income -> 'member_incomes' END,
          NULLIF(v_income ->> 'per_capita_income', '')::numeric
        )
        ON CONFLICT (user_id) DO UPDATE SET
          family_count      = COALESCE(user_income.family_count,      EXCLUDED.family_count),
          social_benefits   = COALESCE(user_income.social_benefits,   EXCLUDED.social_benefits),
          alimony           = COALESCE(user_income.alimony,           EXCLUDED.alimony),
          member_incomes    = COALESCE(user_income.member_incomes,    EXCLUDED.member_incomes),
          per_capita_income = COALESCE(user_income.per_capita_income, EXCLUDED.per_capita_income),
          updated_at        = now()
        WHERE user_income.per_capita_income IS NULL
           OR user_income.family_count      IS NULL
           OR user_income.social_benefits   IS NULL
           OR user_income.alimony           IS NULL
           OR user_income.member_incomes    IS NULL;
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
$$;


ALTER FUNCTION "public"."backfill_eligibility_and_mappings"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."backfill_eligibility_and_mappings"() IS 'Reprocessa applications SUBMITTED/redirected aplicando partner_forms.mapping_source para user_profiles.%, user_preferences.% e user_income.% (fill-if-null). Respostas de renda em faixa textual sao ignoradas por nao serem renda per capita.';



CREATE OR REPLACE FUNCTION "public"."bulk_import_important_dates"("p_dates" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_count INTEGER := 0;
    v_item JSONB;
BEGIN
    -- Permission check
    IF NOT EXISTS (
        SELECT 1 FROM public.user_permissions
        WHERE user_id = auth.uid()
        AND permission = 'Calendário'
    ) THEN
        RAISE EXCEPTION 'Acesso negado. Permissão insuficiente.';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_dates)
    LOOP
        INSERT INTO public.important_dates (title, description, start_date, end_date, type)
        VALUES (
            v_item->>'title',
            v_item->>'description',
            (v_item->>'start_date')::timestamptz,
            NULLIF(v_item->>'end_date', '')::timestamptz,
            v_item->>'type'
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."bulk_import_important_dates"("p_dates" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_application_eligibility"("p_application_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_app_record RECORD;
    v_profile_id UUID;
    v_profile_json JSONB;
    v_form_record RECORD;
    v_partner_results JSONB := '{}'::jsonb;
    v_value JSONB;
    v_met BOOLEAN;
    v_partner_id UUID;
    v_results JSONB;
    v_existing_results JSONB;
    v_merged_results JSONB := '[]'::jsonb;
    v_existing_partner JSONB;
    v_found BOOLEAN := false;
BEGIN
    -- 1. Get application data
    SELECT * INTO v_app_record FROM public.student_applications WHERE id = p_application_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Application not found');
    END IF;

    v_partner_id := v_app_record.partner_id;
    v_profile_id := COALESCE(v_app_record.target_id, v_app_record.user_id);

    -- 2. Get target profile for fallback (age, etc) - also get current eligibility_results
    SELECT to_jsonb(p.*), COALESCE(p.eligibility_results, '[]'::jsonb) 
    INTO v_profile_json, v_existing_results 
    FROM public.user_profiles p 
    WHERE p.id = v_profile_id;

    -- 3. Initialize results for this specific partner
    v_partner_results := jsonb_build_object(
        'partner_id', v_partner_id,
        'partner_name', (SELECT name FROM public.partners WHERE id = v_partner_id),
        'total_criteria', 0,
        'met_criteria', 0,
        'details', '[]'::jsonb
    );

    -- 4. Evaluate each criterion from partner_forms
    FOR v_form_record IN 
        SELECT field_name, mapping_source, criterion_rule 
        FROM public.partner_forms 
        WHERE partner_id = v_partner_id AND is_criterion = true
    LOOP
        BEGIN
            v_value := NULL;
            v_met := false;

            -- Priority 1: Field Name in application answers
            IF v_app_record.answers ? v_form_record.field_name THEN
                v_value := v_app_record.answers -> v_form_record.field_name;
            -- Priority 2: Mapping Source in application answers (agent pre-fill legacy)
            ELSIF v_form_record.mapping_source IS NOT NULL AND v_app_record.answers ? v_form_record.mapping_source THEN
                v_value := v_app_record.answers -> v_form_record.mapping_source;
            -- Priority 3: Fallback to user profile if mapped
            ELSIF v_form_record.mapping_source LIKE 'user_profiles.%' THEN
                v_value := v_profile_json -> split_part(v_form_record.mapping_source, '.', 2);
            END IF;

            -- Only count if value exists
            IF v_value IS NOT NULL AND v_value::text <> 'null' AND v_value::text <> '""' THEN
                -- Increment total criteria
                v_partner_results := jsonb_set(v_partner_results, '{total_criteria}', 
                    to_jsonb((v_partner_results->>'total_criteria')::int + 1));

                -- Evaluation: Real logic evaluation in SQL
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
                    v_partner_results := jsonb_set(v_partner_results, '{met_criteria}', 
                        to_jsonb((v_partner_results->>'met_criteria')::int + 1));
                END IF;

                -- Add detail
                v_partner_results := jsonb_set(v_partner_results, '{details}', 
                    (v_partner_results->'details') || jsonb_build_object('field', v_form_record.field_name, 'met', v_met));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error processing criterion % for partner %: %', v_form_record.field_name, v_partner_id, SQLERRM;
        END;
    END LOOP;

    -- 5. Prepare results array (MERGE with existing instead of overwriting)
    v_results := jsonb_build_array(v_partner_results);
    
    -- Loop through existing results to construct the new merged array
    IF jsonb_typeof(v_existing_results) = 'array' THEN
        FOR v_existing_partner IN SELECT * FROM jsonb_array_elements(v_existing_results)
        LOOP
            -- If it's the partner we just updated, use the new results
            IF (v_existing_partner->>'partner_id') = v_partner_id::text THEN
                v_merged_results := v_merged_results || v_partner_results;
                v_found := true;
            -- Otherwise keep the existing partner data
            ELSE
                v_merged_results := v_merged_results || v_existing_partner;
            END IF;
        END LOOP;
        
        -- If partner wasn't in existing results, append it
        IF NOT v_found THEN
            v_merged_results := v_merged_results || v_partner_results;
        END IF;
    ELSE
        -- Fallback if existing is not an array for some reason
        v_merged_results := v_results;
    END IF;

    -- 6. Update user_profiles -- Update the auth user, not necessarily the target
    UPDATE public.user_profiles SET eligibility_results = v_merged_results WHERE id = v_app_record.user_id;

    RETURN v_merged_results;
END;
$$;


ALTER FUNCTION "public"."calculate_application_eligibility"("p_application_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_match"("p_profile_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
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
    v_quota_types           TEXT[];

    v_nota_linguagens        NUMERIC;
    v_nota_ciencias_humanas  NUMERIC;
    v_nota_ciencias_natureza NUMERIC;
    v_nota_matematica        NUMERIC;
    v_nota_redacao           NUMERIC;
    v_enem_avg               NUMERIC;
    v_has_enem               BOOLEAN := false;
    v_is_treineiro_score     BOOLEAN := false;

    v_weights              JSONB;
    v_enem_window_sisu     INT     := 3;
    v_salario_minimo       NUMERIC := 1621.00;
    v_has_funnel_filters   BOOLEAN;

    v_sisu_year       INT;
    v_sisu_semester   TEXT;
    v_prouni_year     INT;
    v_prouni_semester TEXT;

    v_course_group_courses TEXT[];
    v_academic_floor       NUMERIC := 50.0;
    v_user_tags             TEXT[] := '{}';
    v_pref_city_lat        NUMERIC;
    v_pref_city_lon        NUMERIC;
BEGIN
    -- Serialize execution for the same profile_id to prevent concurrent runs inserting duplicate matches
    PERFORM pg_advisory_xact_lock(hashtext(p_profile_id::text));

    -- 0. Active cycles
    SELECT cycle_year, cycle_semester INTO v_sisu_year, v_sisu_semester
    FROM public.programs WHERE LOWER(type) = 'sisu' AND status <> 'inactive'
    ORDER BY cycle_year DESC, cycle_semester DESC LIMIT 1;

    SELECT cycle_year, cycle_semester INTO v_prouni_year, v_prouni_semester
    FROM public.programs WHERE LOWER(type) = 'prouni' AND status <> 'inactive'
    ORDER BY cycle_year DESC, cycle_semester DESC LIMIT 1;

    IF v_sisu_year IS NULL    THEN v_sisu_year := 2025;    v_sisu_semester := '1'; END IF;
    IF v_prouni_year IS NULL  THEN v_prouni_year := 2025;  v_prouni_semester := '1'; END IF;

    -- 1. User preferences
    SELECT
        up.family_income_per_capita, up.course_interest, up.preferred_shifts,
        up.university_preference, up.program_preference, up.state_preference,
        up.location_preference, up.device_latitude, up.device_longitude, up.quota_types
    INTO
        v_income, v_course_interests, v_preferred_shifts,
        v_university_preference, v_program_preference, v_state_preference,
        v_location_preference, v_lat, v_lon, v_quota_types
    FROM public.user_preferences up WHERE up.user_id = p_profile_id;

    -- Build user tags list combining quota types, income tags and general tags
    v_user_tags := COALESCE(v_quota_types, '{}'::TEXT[]) || ARRAY['SEM_CRITERIO_RENDA', 'AMPLA_CONCORRENCIA'];

    IF v_income IS NOT NULL THEN
        IF v_income <= v_salario_minimo * 1.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_1_SM', 'RENDA_ATE_1_5_SM', 'RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 1.5 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_1_5_SM', 'RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 2.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_2_SM', 'RENDA_ATE_4_SM'];
        ELSIF v_income <= v_salario_minimo * 4.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_4_SM'];
        END IF;
    END IF;

    -- 1b. Cidade de preferência como âncora geográfica: resolve location_preference
    --     (+state_preference quando presente) em lat/long via public.cities.
    --     Preferência explícita SOBRESCREVE as coordenadas do device — o usuário pode
    --     morar em X e querer estudar perto de Y.
    IF v_location_preference IS NOT NULL AND TRIM(v_location_preference) <> '' THEN
        SELECT c.latitude, c.longitude INTO v_pref_city_lat, v_pref_city_lon
        FROM public.cities c
        WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(TRIM(v_location_preference)))
          AND (v_state_preference IS NULL OR upper(c.state) = upper(v_state_preference))
        LIMIT 1;

        IF v_pref_city_lat IS NOT NULL AND v_pref_city_lon IS NOT NULL THEN
            v_lat := v_pref_city_lat;
            v_lon := v_pref_city_lon;
        END IF;
    END IF;

    -- 1c. Preferência EAD casa com os rótulos reais do MEC. Sem isso, 'EAD' nunca
    --     iguala shift='Curso a distância' (ProUni) → excluída do funil e shift_score=0.
    IF v_preferred_shifts IS NOT NULL
       AND ('EAD' = ANY(v_preferred_shifts) OR 'EaD' = ANY(v_preferred_shifts)
            OR 'Curso a distância' = ANY(v_preferred_shifts)) THEN
        v_preferred_shifts := v_preferred_shifts || ARRAY['Curso a distância', 'EaD', 'EAD'];
    END IF;

    -- 2. ENEM scores (Absolute Highest, fallback to treineiro badge if it's the highest)
    SELECT ues.nota_linguagens, ues.nota_ciencias_humanas, ues.nota_ciencias_natureza,
           ues.nota_matematica, ues.nota_redacao, ues.is_treineiro
    INTO   v_nota_linguagens, v_nota_ciencias_humanas, v_nota_ciencias_natureza,
           v_nota_matematica, v_nota_redacao, v_is_treineiro_score
    FROM public.user_enem_scores ues
    WHERE ues.user_id = p_profile_id
      AND ues.year >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - v_enem_window_sisu)
    ORDER BY (COALESCE(ues.nota_linguagens,0)+COALESCE(ues.nota_ciencias_humanas,0)+
              COALESCE(ues.nota_ciencias_natureza,0)+COALESCE(ues.nota_matematica,0)+
              COALESCE(ues.nota_redacao,0)) DESC,
              ues.is_treineiro ASC -- desempate: oficial vence treineiro
    LIMIT 1;

    IF v_is_treineiro_score IS NULL THEN
        v_is_treineiro_score := false;
    END IF;

    IF v_nota_linguagens IS NOT NULL THEN
        v_has_enem := true;
        v_enem_avg := (COALESCE(v_nota_linguagens,0)+COALESCE(v_nota_ciencias_humanas,0)+
                       COALESCE(v_nota_ciencias_natureza,0)+COALESCE(v_nota_matematica,0)+
                       COALESCE(v_nota_redacao,0)) / 5.0;
    END IF;

    -- 3. Weights
    SELECT jsonb_object_agg(weight_key, weight_value) INTO v_weights
    FROM public.match_config WHERE is_active = true;
    IF v_weights IS NULL THEN
        v_weights := '{"performance_weight":0.40,"preference_weight":0.30,"location_weight":0.20,
                       "partner_boost":1.15,"partner_boost_cap":20,"idle_vacancy_boost":5,"cota_bonus":10,
                       "score_decay_above_cutoff":0.3,"score_decay_below_cutoff":0.9,"academic_score_floor":50}'::jsonb;
    END IF;
    v_academic_floor := COALESCE((v_weights->>'academic_score_floor')::NUMERIC, 50.0);

    -- 4. Course group fallback
    IF v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0 THEN
        SELECT array_agg(DISTINCT unnest_courses) INTO v_course_group_courses
        FROM (
            SELECT unnest(cg.courses) AS unnest_courses
            FROM public.course_groups cg
            WHERE EXISTS (
                SELECT 1 FROM unnest(v_course_interests) ci
                WHERE cg.courses @> ARRAY[UPPER(ci)]
            )
        ) sub;
    END IF;

    -- 5. Funnel filter flag
    v_has_funnel_filters := (
        (v_program_preference IS NOT NULL AND v_program_preference != 'indiferente') OR
        (v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0) OR
        v_state_preference IS NOT NULL OR
        (v_preferred_shifts IS NOT NULL AND cardinality(v_preferred_shifts) > 0)
    );

    -- 6. Clear old matches
    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    -- 7. MEC funnel
    CREATE TEMP TABLE _mec_funnel (
        opp_id              uuid,
        unified_id          text,
        course_id           uuid,
        course_name         text,
        opportunity_type    text,
        scholarship_type    text,
        concurrency_type    text,
        concurrency_tags    jsonb,
        cutoff_score        numeric,
        shift               text,
        is_partner          boolean,
        campus_lat          numeric,
        campus_lon          numeric,
        campus_state        text,
        campus_city         text,
        institution_id      uuid,
        peso_linguagens     numeric,
        peso_ciencias_humanas numeric,
        peso_ciencias_natureza numeric,
        peso_matematica     numeric,
        peso_redacao        numeric,
        has_vagas_ociosas   boolean,
        eligibility_criteria jsonb
    ) ON COMMIT DROP;

    IF v_has_funnel_filters THEN
        -- Path A: funnel com fallback por grupo CNPq quando curso exato não existe no ciclo
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               false,
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
          AND (v_program_preference IS NULL OR v_program_preference = 'indiferente'
               OR o.opportunity_type = v_program_preference)
          AND (
              v_course_interests IS NULL OR cardinality(v_course_interests) = 0
              OR
              EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                      WHERE c.course_name ILIKE '%'||ci||'%')
              OR
              (v_course_group_courses IS NOT NULL
               AND UPPER(c.course_name) = ANY(v_course_group_courses))
          )
          AND (v_state_preference IS NULL OR cp.state = v_state_preference)
          AND (v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0
               OR o.shift = ANY(v_preferred_shifts))
        -- 3.1 Funil por relevância: match de curso primeiro, depois proximidade (agnóstico a tipo)
        ORDER BY
          (CASE
             WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 1
             WHEN EXISTS (SELECT 1 FROM unnest(v_course_interests) ci WHERE c.course_name ILIKE '%'||ci||'%') THEN 0
             WHEN v_course_group_courses IS NOT NULL AND UPPER(c.course_name) = ANY(v_course_group_courses) THEN 0
             ELSE 1
           END) ASC,
          (CASE
             WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
               THEN public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude)
             ELSE 999999
           END) ASC
        LIMIT 1500;

    ELSIF v_lat IS NOT NULL AND v_lon IS NOT NULL THEN
        -- Path B: geolocalização
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               false,
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
          AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
          AND cp.latitude BETWEEN (v_lat - 4.5) AND (v_lat + 4.5)
          AND cp.longitude BETWEEN (v_lon - 5.5) AND (v_lon + 5.5)
          AND public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) <= 500
        -- 3.1 Funil por relevância: mais próximos primeiro (agnóstico a tipo)
        ORDER BY public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) ASC
        LIMIT 1500;

    ELSE
        -- Path C: hash random
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               false,
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
        ORDER BY hashtext(c.id::text || p_profile_id::text)
        LIMIT 1000;
    END IF;

    -- Update has_vagas_ociosas efficiently for the reduced set of opportunities
    UPDATE _mec_funnel m
    SET has_vagas_ociosas = true
    WHERE EXISTS (
        SELECT 1 FROM public.opportunities_sisu_vacancies sv2
        WHERE sv2.opportunity_id = m.opp_id
          AND sv2.qt_vagas_ofertadas IS NOT NULL
          AND sv2.qt_inscricao IS NOT NULL
          AND replace(sv2.qt_vagas_ofertadas, '.', '')::int > sv2.qt_inscricao::int
    ) OR EXISTS (
        SELECT 1 FROM public.opportunities_prouni_vacancies pv2
        WHERE pv2.opportunity_id = m.opp_id
          AND (COALESCE(pv2.bolsas_ampla_ofertada,0) + COALESCE(pv2.bolsas_cota_ofertada,0))
            > (COALESCE(pv2.bolsas_ampla_ocupada,0) + COALESCE(pv2.bolsas_cota_ocupada,0))
    );

    -- 8. Score and persist
    INSERT INTO public.user_opportunity_matches
        (profile_id, unified_opportunity_id, match_score, match_details)

    WITH

    all_opportunities AS (
        SELECT * FROM _mec_funnel
        UNION ALL
        SELECT po.id, 'partner_'||po.id::text, NULL::uuid, po.name,
               'partner', NULL, NULL, NULL::jsonb, NULL::numeric, NULL,
               true, NULL::numeric, NULL::numeric, NULL, NULL,
               po.institution_id, NULL, NULL, NULL, NULL, NULL, false::boolean,
               po.eligibility_criteria
        FROM public.partner_opportunities po
        WHERE po.status::text IN ('approved', 'incoming', 'opened')
    ),

    scored_performance AS (
        SELECT
            ao.*,
            CASE
                WHEN ao.opportunity_type = 'prouni' AND ao.scholarship_type ILIKE '%Integral%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                WHEN ao.opportunity_type = 'prouni' AND ao.scholarship_type ILIKE '%Parcial%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 3.0 THEN false
                WHEN ao.opportunity_type = 'sisu' AND ao.concurrency_type ILIKE '%renda%'
                     AND NOT EXISTS (
                         SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS ts
                         WHERE ts ? 'SEM_CRITERIO_RENDA'
                     )
                     AND ao.concurrency_type NOT ILIKE '%independentemente%da%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independentemente%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independente%da%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independente%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%qualquer%renda%'
                     AND ao.concurrency_type NOT ILIKE '%sem%critério%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%não%declarem%ser%oriundos%de%famílias%com%renda%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                ELSE true
            END AS meets_income,
            CASE
                -- ProUni: a cota do programa é exclusivamente PPI (Pretos, Pardos e
                -- Indígenas) — dado do MEC (TP_MODALIDADE = AMPLA/PPI). Só é elegível
                -- quem declarou PPI ou INDIGENAS, e a opportunity oferta vagas de cota.
                WHEN ao.opportunity_type = 'prouni' THEN
                    (COALESCE(v_quota_types, '{}'::text[]) && ARRAY['PPI','INDIGENAS']
                     AND EXISTS (
                         SELECT 1 FROM public.opportunities_prouni_vacancies pvq
                         WHERE pvq.opportunity_id = ao.opp_id
                           AND COALESCE(pvq.bolsas_cota_ofertada, 0) > 0
                     ))
                WHEN ao.concurrency_tags IS NULL OR jsonb_array_length(ao.concurrency_tags) = 0 THEN false
                WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS tag_set
                    WHERE NOT (
                        jsonb_array_length(tag_set) = 1 AND tag_set->>0 = 'AMPLA_CONCORRENCIA'
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(tag_set) AS tag
                        WHERE NOT (tag = ANY(v_user_tags))
                    )
                ) THEN true
                ELSE false
            END AS cota_eligible,
            CASE
                WHEN v_has_enem AND ao.peso_linguagens IS NOT NULL THEN
                    (COALESCE(v_nota_linguagens,0)*COALESCE(ao.peso_linguagens::numeric,1)+
                     COALESCE(v_nota_ciencias_humanas,0)*COALESCE(ao.peso_ciencias_humanas::numeric,1)+
                     COALESCE(v_nota_ciencias_natureza,0)*COALESCE(ao.peso_ciencias_natureza::numeric,1)+
                     COALESCE(v_nota_matematica,0)*COALESCE(ao.peso_matematica::numeric,1)+
                     COALESCE(v_nota_redacao,0)*COALESCE(ao.peso_redacao::numeric,1))
                    / NULLIF(COALESCE(ao.peso_linguagens::numeric,1)+COALESCE(ao.peso_ciencias_humanas::numeric,1)+
                             COALESCE(ao.peso_ciencias_natureza::numeric,1)+COALESCE(ao.peso_matematica::numeric,1)+
                             COALESCE(ao.peso_redacao::numeric,1), 0)
                WHEN v_has_enem THEN v_enem_avg
                ELSE NULL
            END AS weighted_enem_score
        FROM all_opportunities ao
    ),

    scored_academic AS (
        SELECT sp.*,
            CASE
                -- Parceiro NÃO usa pilar acadêmico (ver evaluate_partner_eligibility)
                WHEN sp.is_partner THEN NULL
                WHEN sp.weighted_enem_score IS NOT NULL AND sp.cutoff_score IS NOT NULL AND sp.cutoff_score > 0 THEN
                    GREATEST(v_academic_floor, LEAST(100.0,
                        (100.0 - CASE
                            WHEN sp.weighted_enem_score >= sp.cutoff_score THEN
                                (sp.weighted_enem_score - sp.cutoff_score) * COALESCE((v_weights->>'score_decay_above_cutoff')::NUMERIC, 0.3)
                            ELSE
                                (sp.cutoff_score - sp.weighted_enem_score) * COALESCE((v_weights->>'score_decay_below_cutoff')::NUMERIC, 0.9)
                         END)
                        * CASE WHEN v_is_treineiro_score THEN 0.85 ELSE 1.0 END))
                -- MEC sem corte OU sem ENEM → piso (informação ausente = neutro)
                ELSE v_academic_floor
            END AS academic_score
        FROM scored_performance sp
    ),

    scored_preferences AS (
        SELECT sa.*,
            CASE WHEN v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts)=0 THEN 50.0
                 WHEN sa.shift IS NULL THEN 50.0
                 WHEN sa.shift = ANY(v_preferred_shifts) THEN 100.0
                 ELSE 0.0 END AS shift_score,
            CASE WHEN v_university_preference IS NULL OR v_university_preference='indiferente' THEN 50.0
                 WHEN v_university_preference='publica'  AND sa.opportunity_type='sisu'               THEN 100.0
                 WHEN v_university_preference='privada'  AND sa.opportunity_type IN ('prouni','partner') THEN 100.0
                 ELSE 20.0 END
            + CASE WHEN v_program_preference IS NULL OR v_program_preference='indiferente' THEN 50.0
                   WHEN v_program_preference='sisu'   AND sa.opportunity_type='sisu'   THEN 100.0
                   WHEN v_program_preference='prouni' AND sa.opportunity_type='prouni' THEN 100.0
                   ELSE 20.0 END AS inst_program_score_raw,
            CASE
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE LOWER(sa.course_name) = LOWER(ci)) THEN 100.0
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE sa.course_name ILIKE '%'||ci||'%') THEN 85.0
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND v_course_group_courses IS NOT NULL
                     AND UPPER(sa.course_name) = ANY(v_course_group_courses) THEN 70.0
                WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 50.0
                ELSE 10.0
            END AS course_score
        FROM scored_academic sa
    ),

    scored_location AS (
        SELECT sp.*,
            LEAST(100.0, sp.inst_program_score_raw/2.0) AS inst_program_score,
            CASE
                WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL
                     AND sp.campus_lat IS NOT NULL AND sp.campus_lon IS NOT NULL THEN
                    GREATEST(0.0, 100.0 - public.haversine_km(v_lat, v_lon, sp.campus_lat, sp.campus_lon)*0.5)
                ELSE 40.0
            END AS distance_score,
            CASE WHEN v_state_preference IS NOT NULL AND sp.campus_state IS NOT NULL
                      AND LOWER(sp.campus_state)=LOWER(v_state_preference) THEN 30.0
                 WHEN v_location_preference IS NOT NULL AND sp.campus_city IS NOT NULL
                      AND LOWER(sp.campus_city) ILIKE '%'||LOWER(v_location_preference)||'%' THEN 30.0
                 ELSE 0.0 END AS regional_bonus
        FROM scored_preferences sp
    ),

    composite AS (
        SELECT sl.opp_id, sl.concurrency_type, sl.concurrency_tags,
               sl.unified_id, sl.course_id, sl.is_partner, sl.meets_income, sl.cota_eligible,
               sl.academic_score, sl.shift_score, sl.inst_program_score, sl.course_score,
               sl.distance_score, sl.regional_bonus, sl.weighted_enem_score, sl.cutoff_score,
               sl.has_vagas_ociosas, sl.opportunity_type,
               pe.elig AS partner_elig,
               CASE
                   -- PARCEIRO: pontua por elegibilidade (partner_forms), fora do pipeline MEC
                   WHEN sl.is_partner THEN COALESCE((pe.elig->>'score')::numeric, 100.0)
                   -- MEC: gate de renda
                   WHEN NOT sl.meets_income THEN 0.0
                   -- 3.3 ProUni: gate de elegibilidade ENEM >= 450 (regra do programa)
                   WHEN sl.opportunity_type = 'prouni'
                        AND sl.weighted_enem_score IS NOT NULL
                        AND sl.weighted_enem_score < 450 THEN 0.0
                   -- 3.2 Pesos por oportunidade: pilar sem dado (corte NULL) redistribui seu peso.
                   --     base_score = média ponderada dos pilares COM peso (÷ soma dos pesos usados).
                   ELSE LEAST(100.0, GREATEST(0.0,
                       (
                         (CASE WHEN sl.cutoff_score IS NULL THEN 0.0
                               ELSE COALESCE((v_weights->>'performance_weight')::NUMERIC,0.40) END) * sl.academic_score
                         + COALESCE((v_weights->>'preference_weight')::NUMERIC,0.30) * (
                             sl.shift_score*0.333 + sl.inst_program_score*0.333 + sl.course_score*0.334)
                         + COALESCE((v_weights->>'location_weight')::NUMERIC,0.20) * (
                             LEAST(100.0, sl.distance_score + sl.regional_bonus))
                       ) / NULLIF(
                         (CASE WHEN sl.cutoff_score IS NULL THEN 0.0
                               ELSE COALESCE((v_weights->>'performance_weight')::NUMERIC,0.40) END)
                         + COALESCE((v_weights->>'preference_weight')::NUMERIC,0.30)
                         + COALESCE((v_weights->>'location_weight')::NUMERIC,0.20), 0)
                   ))
               END AS base_score
        FROM scored_location sl
        LEFT JOIN LATERAL (
            SELECT public.evaluate_partner_eligibility(p_profile_id, sl.opp_id) AS elig
            WHERE sl.is_partner
        ) pe ON true
    ),

    boosted AS (
        SELECT c.*,
            CASE
                -- PARCEIRO: elegibilidade + partner_boost (lever de visibilidade configurável)
                WHEN c.is_partner THEN
                    LEAST(c.base_score*COALESCE((v_weights->>'partner_boost')::NUMERIC,1.15),
                          c.base_score+COALESCE((v_weights->>'partner_boost_cap')::NUMERIC,20.0))
                -- MEC fora de renda → 0
                WHEN NOT c.meets_income THEN 0.0
                -- MEC gateado (qualquer gate zerou a base, ex.: ENEM<450 no ProUni) → 0, sem boost
                WHEN c.base_score <= 0.0 THEN 0.0
                -- MEC: base + boosts MEC-only (vagas ociosas, cota)
                ELSE c.base_score
                     + CASE WHEN c.has_vagas_ociosas THEN COALESCE((v_weights->>'idle_vacancy_boost')::NUMERIC, 5.0) ELSE 0.0 END
                     + CASE WHEN c.cota_eligible     THEN COALESCE((v_weights->>'cota_bonus')::NUMERIC,10.0)        ELSE 0.0 END
            END AS final_score,
            jsonb_build_object(
                'score_basis', CASE WHEN c.is_partner THEN 'eligibility' ELSE 'academic' END,
                'partner_eligibility', c.partner_elig,
                'meets_income', c.meets_income, 'cota_eligible', c.cota_eligible,
                'treineiro_score', v_is_treineiro_score,
                'academic_score', round(c.academic_score,2),
                'weighted_enem_score', round(COALESCE(c.weighted_enem_score,0),2),
                'cutoff_score', COALESCE(c.cutoff_score,0),
                'shift_score', round(c.shift_score,2),
                'inst_program_score', round(c.inst_program_score,2),
                'course_score', round(c.course_score,2),
                'distance_score', round(c.distance_score,2),
                'regional_bonus', round(c.regional_bonus,2),
                'base_score', round(c.base_score,2),
                'is_partner', c.is_partner,
                'boost_applied', c.is_partner,
                'idle_vacancy_boost_applied', c.has_vagas_ociosas AND NOT c.is_partner,
                'cota_bonus_applied', (c.cota_eligible AND c.meets_income AND NOT c.is_partner),
                'opportunity_type', c.opportunity_type,
                'best_opportunity_id', c.opp_id,
                'best_concurrency_type', c.concurrency_type,
                'best_concurrency_tags', c.concurrency_tags,
                'cycle', jsonb_build_object('sisu_year',v_sisu_year,'sisu_semester',v_sisu_semester,
                                             'prouni_year',v_prouni_year,'prouni_semester',v_prouni_semester)
            ) AS details
        FROM composite c
    ),

    course_best AS (
        SELECT DISTINCT ON (COALESCE(b.course_id::text, b.unified_id))
            b.unified_id, b.is_partner,
            LEAST(100.0, round(b.final_score,2)) AS final_score,
            b.details
        FROM boosted b
        ORDER BY COALESCE(b.course_id::text, b.unified_id), b.final_score DESC
    ),

    mec_top100 AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best WHERE NOT is_partner
        ORDER BY final_score DESC LIMIT 100
    ),

    partners_all AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best WHERE is_partner
    )

    SELECT p_profile_id, unified_id, final_score, details FROM mec_top100
    UNION ALL
    SELECT p_profile_id, unified_id, final_score, details FROM partners_all;

END;
$$;


ALTER FUNCTION "public"."calculate_match"("p_profile_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calculate_match"("p_profile_id" "uuid") IS 'V4.1: Adiciona fallback por grupo CNPq quando curso exato não existe no ciclo ativo. Score: 100 exato | 85 substring | 70 grupo | 10 sem relação.';



CREATE OR REPLACE FUNCTION "public"."calculate_match_async_worker"("p_profile_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Marcar como processando
    UPDATE public.user_preferences 
    SET match_status = 'processing', last_match_at = now()
    WHERE user_id = p_profile_id;

    -- Executar o motor pesado (V3/V4)
    -- Note: calculate_match returns a table, but here we just want the side effect (inserting into user_opportunity_matches)
    PERFORM public.calculate_match(p_profile_id);

    -- Marcar como concluído
    UPDATE public.user_preferences 
    SET match_status = 'ready'
    WHERE user_id = p_profile_id;
EXCEPTION WHEN OTHERS THEN
    -- Marcar erro em caso de falha
    UPDATE public.user_preferences 
    SET match_status = 'error'
    WHERE user_id = p_profile_id;
    RAISE;
END;
$$;


ALTER FUNCTION "public"."calculate_match_async_worker"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_passport_eligibility"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
      $$;


ALTER FUNCTION "public"."calculate_passport_eligibility"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_nubo_student_eligibility"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    user_phone TEXT;
    clean_user_phone TEXT;
BEGIN
    -- Get phone from auth.users (Requires SECURITY DEFINER to access auth schema if not admin, 
    -- but usually triggers run with privileges of table owner or we can force it)
    -- However, accessing auth.users directly in a trigger for public table can be tricky with permissions.
    -- We'll SELECT into a variable.
    
    SELECT phone INTO user_phone
    FROM auth.users
    WHERE id = NEW.id;

    IF user_phone IS NOT NULL THEN
        -- Clean the phone number from auth.users (assuming Supabase stores it with possible formatting, or just to be safe)
        -- Supabase usually stores as E.164 (e.g. +5511...)
        clean_user_phone := public.clean_phone_number(user_phone);

        -- Check whitelist. We assume whitelist stores numbers without country code if CSV doesn't have it,
        -- OR we need robust matching. 
        -- The CSV shows "(11) 95408-1455". Cleaning gives "11954081455".
        -- auth.users usually has E.164: "5511954081455".
        -- MATCHING STRATEGY: Check if clean_user_phone ENDS WITH the whitelisted number.
        
        PERFORM 1 
        FROM public.nubo_student_whitelist
        WHERE clean_user_phone LIKE '%' || phone_number;
        
        IF FOUND THEN
            NEW.is_nubo_student := TRUE;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_nubo_student_eligibility"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clean_numeric_string"("val" "text") RETURNS numeric
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF val IS NULL OR TRIM(val) = '' THEN
        RETURN NULL;
    END IF;
    RETURN REPLACE(REPLACE(TRIM(val), '.', ''), ',', '.')::NUMERIC;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."clean_numeric_string"("val" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clean_phone_number"("input_phone" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN regexp_replace(input_phone, '\D', '', 'g');
END;
$$;


ALTER FUNCTION "public"."clean_phone_number"("input_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cron_check_deadlines"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'net'
    AS $$
DECLARE
    v_supabase_url TEXT;
    v_service_key  TEXT;
    v_net_id       BIGINT;
    v_missing      TEXT[] := ARRAY[]::TEXT[];
BEGIN
    -- nullif(trim(...)) para que string vazia conte como ausente: um setting
    -- provisionado com valor em branco falharia igual, mas passaria pelo
    -- IS NOT NULL da versão anterior.
    v_supabase_url := nullif(trim(coalesce(current_setting('app.settings.supabase_url', true), '')), '');
    v_service_key  := nullif(trim(coalesce(current_setting('app.settings.service_role_key', true), '')), '');

    -- array_append e não `||`: com uma string literal, `anyarray || anyelement`
    -- e `anyarray || anyarray` ficam ambíguos e o Postgres tenta interpretar o
    -- texto como literal de array ("malformed array literal").
    IF v_supabase_url IS NULL THEN
        v_missing := array_append(v_missing, 'app.settings.supabase_url');
    END IF;

    IF v_service_key IS NULL THEN
        v_missing := array_append(v_missing, 'app.settings.service_role_key');
    END IF;

    IF array_length(v_missing, 1) > 0 THEN
        RAISE EXCEPTION
            'cron_check_deadlines: configuração ausente (%). O job não tem como chamar a Edge Function e nenhum admin_alert será gerado. Provisione com ALTER DATABASE ... SET <setting> = ...',
            array_to_string(v_missing, ', ')
            USING ERRCODE = 'configuration_limit_exceeded';
    END IF;

    SELECT net.http_post(
        url := v_supabase_url || '/functions/v1/check-opportunity-deadlines',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_service_key,
            'Content-Type', 'application/json',
            'apikey', v_service_key
        ),
        body := '{}'::jsonb
    ) INTO v_net_id;

    IF v_net_id IS NULL THEN
        RAISE EXCEPTION
            'cron_check_deadlines: net.http_post não devolveu request id — a chamada não foi enfileirada';
    END IF;

    -- net.http_post é assíncrono: enfileirar não é o mesmo que ter respondido.
    -- O id vai para cron.job_run_details e permite cruzar com net._http_response
    -- para saber o que a Edge Function respondeu de fato.
    RAISE NOTICE 'cron_check_deadlines: requisição % enfileirada para %', v_net_id, v_supabase_url;
END;
$$;


ALTER FUNCTION "public"."cron_check_deadlines"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cron_check_deadlines"() IS 'Dispara a Edge Function check-opportunity-deadlines (ADR-0024). Falha explicitamente se app.settings.supabase_url ou app.settings.service_role_key não estiverem provisionados — a versão anterior retornava sucesso vazio e mascarou o Action Center vazio por meses. Agendada em cron.job id 2, 0 8 * * *.';



CREATE OR REPLACE FUNCTION "public"."ensure_single_active_program"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- If the new/updated program is active (incoming, opened, closed), set all others of same type to 'inactive'
  IF NEW.status IN ('incoming', 'opened', 'closed') THEN
    UPDATE public.programs
    SET status = 'inactive',
        updated_at = now()
    WHERE type = NEW.type
      AND id <> NEW.id
      AND status IN ('incoming', 'opened', 'closed');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."ensure_single_active_program"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_clone_prouni_cycle"("p_source_program_id" "uuid", "p_target_program_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $$
DECLARE
  v_src_year      INTEGER;
  v_src_semester  TEXT;
  v_tgt_year      INTEGER;
  v_tgt_semester  TEXT;
  v_log_id        UUID;
  v_opp_cloned    INTEGER := 0;
  v_vac_cloned    INTEGER := 0;
  v_errors        TEXT;
  v_detail_msg    TEXT;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_src_year, v_src_semester
  FROM public.programs WHERE id = p_source_program_id;
  IF v_src_year IS NULL THEN RAISE EXCEPTION 'Source program not found'; END IF;

  SELECT cycle_year, cycle_semester INTO v_tgt_year, v_tgt_semester
  FROM public.programs WHERE id = p_target_program_id;
  IF v_tgt_year IS NULL THEN RAISE EXCEPTION 'Target program not found'; END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
  VALUES (p_target_program_id, 'prouni_clone', 'running', now(), 0)
  RETURNING id INTO v_log_id;

  BEGIN
    -- 1. Clone opportunities
    WITH source_opps AS (
      SELECT * FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_src_year
        AND semester = v_src_semester
    ),
    cloned_opps AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, scholarship_type, concurrency_type,
        year, opportunity_type, cutoff_score, raw_data,
        scholarship_tags, is_nubo_pick
      )
      SELECT
        so.course_id,
        v_tgt_semester,
        so.shift,
        so.scholarship_type,
        so.concurrency_type,
        v_tgt_year,
        so.opportunity_type,
        so.cutoff_score,
        so.raw_data,
        so.scholarship_tags,
        so.is_nubo_pick
      FROM source_opps so
      ON CONFLICT DO NOTHING
      RETURNING id
    )
    SELECT COUNT(*) INTO v_opp_cloned FROM cloned_opps;

    -- 2. Clone vacancies mapeando origem -> destino pelo GRÃO COMPLETO
    --    (course_id, shift, scholarship_type) — antes faltava scholarship_type,
    --    gerando pareamento cartesiano com o grão Integral/Parcial.
    WITH source_opps AS (
      SELECT id AS src_opp_id, course_id, shift, scholarship_type
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_src_year
        AND semester = v_src_semester
    ),
    new_opps AS (
      SELECT id AS new_opp_id, course_id, shift, scholarship_type
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_tgt_year
        AND semester = v_tgt_semester
    ),
    cloned_vacs AS (
      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id,
        bolsas_ampla_ofertada, bolsas_cota_ofertada,
        bolsas_ampla_ocupada, bolsas_cota_ocupada
      )
      SELECT
        no.new_opp_id,
        pv.bolsas_ampla_ofertada,
        pv.bolsas_cota_ofertada,
        pv.bolsas_ampla_ocupada,
        pv.bolsas_cota_ocupada
      FROM public.opportunities_prouni_vacancies pv
      JOIN source_opps so ON so.src_opp_id = pv.opportunity_id
      JOIN new_opps no ON no.course_id = so.course_id
        AND no.shift IS NOT DISTINCT FROM so.shift
        AND no.scholarship_type IS NOT DISTINCT FROM so.scholarship_type
      ON CONFLICT (opportunity_id) DO NOTHING
      RETURNING opportunity_id
    )
    SELECT COUNT(*) INTO v_vac_cloned FROM cloned_vacs;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    v_detail_msg := 'Ciclo ProUni clonado com sucesso.' || chr(10)
      || '• Origem: ' || v_src_year || '.' || v_src_semester || chr(10)
      || '• Destino: ' || v_tgt_year || '.' || v_tgt_semester || chr(10)
      || '• Oportunidades clonadas: ' || v_opp_cloned || chr(10)
      || '• Vagas clonadas: ' || v_vac_cloned;

    UPDATE public.etl_run_logs
    SET status = 'success', errors = v_detail_msg, finished_at = now(),
        records_processed = v_opp_cloned + v_vac_cloned
    WHERE id = v_log_id;

    UPDATE public.programs SET is_fully_imported = true WHERE id = p_target_program_id;
    UPDATE public.programs SET prev_program_id = p_source_program_id WHERE id = p_target_program_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'opp_cloned', v_opp_cloned,
    'vac_cloned', v_vac_cloned,
    'log_id', v_log_id,
    'errors', v_errors
  );

EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('status', 'error', 'opp_cloned', 0, 'vac_cloned', 0, 'errors', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."etl_clone_prouni_cycle"("p_source_program_id" "uuid", "p_target_program_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_emec"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $_$
DECLARE
  v_log_id              UUID;
  v_processed           INTEGER := 0;
  v_errors              TEXT;
  v_rec                 RECORD;
  v_inst_id             UUID;
  -- Rich logging counters
  v_raw_count           INTEGER;
  v_unmatched           INTEGER;
  v_emec_total          INTEGER;
  v_with_igc            INTEGER;
  v_with_ci             INTEGER;
  v_federal             INTEGER;
  v_estadual            INTEGER;
  v_privado             INTEGER;
  v_detail_msg          TEXT;
BEGIN
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

  -- ── Rich post-run stats ──────────────────────────────────────────────────
  SELECT COUNT(DISTINCT "Código IES") INTO v_raw_count FROM public.rawemec WHERE "Código IES" IS NOT NULL;
  v_unmatched := v_raw_count - v_processed;

  SELECT COUNT(*) INTO v_emec_total FROM public.institutions_info_emec;

  SELECT COUNT(*) INTO v_with_igc
  FROM public.institutions_info_emec
  WHERE igc IS NOT NULL AND igc > 0;

  SELECT COUNT(*) INTO v_with_ci
  FROM public.institutions_info_emec
  WHERE ci IS NOT NULL AND ci > 0;

  SELECT COUNT(*) INTO v_federal
  FROM public.institutions_info_emec
  WHERE UPPER(administrative_category) LIKE '%FEDERAL%';

  SELECT COUNT(*) INTO v_estadual
  FROM public.institutions_info_emec
  WHERE UPPER(administrative_category) LIKE '%ESTADUAL%';

  SELECT COUNT(*) INTO v_privado
  FROM public.institutions_info_emec
  WHERE UPPER(administrative_category) LIKE '%PRIVAD%';

  IF v_errors IS NULL THEN
    v_detail_msg :=
      'Metadados e-MEC importados com sucesso.' ||
      chr(10) || '• IES distintas no arquivo:       ' || v_raw_count ||
      chr(10) || '• IES atualizadas (com match):    ' || v_processed ||
      chr(10) || '• IES sem match (não cadastradas):' || v_unmatched ||
      chr(10) || '• Total em institutions_info_emec:' || v_emec_total ||
      chr(10) || '• IES com IGC:                    ' || v_with_igc ||
      chr(10) || '• IES com CI:                     ' || v_with_ci ||
      chr(10) || '• Federais / Estaduais / Privadas: ' || v_federal || ' / ' || v_estadual || ' / ' || v_privado;

    UPDATE public.etl_run_logs
    SET status = 'success',
        records_processed = v_processed,
        errors = v_detail_msg,
        finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error',
        records_processed = v_processed,
        errors = v_errors,
        finished_at = now()
    WHERE id = v_log_id;

    -- Clear raw table to free space and prevent accidental re-runs
    TRUNCATE TABLE public.rawemec;
  END IF;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'unmatched', v_unmatched,
    'with_igc', v_with_igc,
    'with_ci', v_with_ci,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;

    -- Clear raw table to free space and prevent accidental re-runs
    TRUNCATE TABLE public.rawemec;
  END IF;

  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$_$;


ALTER FUNCTION "public"."etl_import_emec"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_emec"("p_limit" integer DEFAULT NULL::integer, "p_offset" integer DEFAULT 0, "p_log_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $_$
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
  v_batch_rows        INTEGER := 0;
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

  IF p_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_batch_rows FROM (
      SELECT 1 FROM public.rawemec LIMIT p_limit OFFSET p_offset
    ) sub;
    v_has_more := (v_batch_rows = p_limit);
  ELSE
    v_has_more := FALSE;
  END IF;

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
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$_$;


ALTER FUNCTION "public"."etl_import_emec"("p_limit" integer, "p_offset" integer, "p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_prouni"("p_program_id" "uuid", "p_limit" integer DEFAULT 5000, "p_after_ctid" "text" DEFAULT NULL::"text", "p_log_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_opp_integral      INTEGER;
  v_opp_parcial       INTEGER;
  v_opp_with_cutoff   INTEGER;
  v_vacancies_count   INTEGER;
  v_ampla_ofertada    BIGINT;
  v_cota_ofertada     BIGINT;
  v_ampla_ocupada     BIGINT;
  v_cota_ocupada      BIGINT;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
  v_batch_rows        INTEGER := 0;
  v_next_ctid         TID;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouni;

  IF p_log_id IS NULL THEN
    PERFORM public.etl_reap_stale_runs();

    IF EXISTS (
      SELECT 1 FROM public.etl_run_logs
      WHERE program_id = p_program_id AND etl_type = 'prouni_base' AND status = 'running'
    ) THEN
      RAISE EXCEPTION 'Já existe uma importação ProUni em andamento para este ciclo. Aguarde ou pare a execução atual.';
    END IF;

    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed, backend_pid)
    VALUES (p_program_id, 'prouni_base', 'running', now(), 0, pg_backend_pid())
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
    UPDATE public.etl_run_logs SET backend_pid = pg_backend_pid() WHERE id = v_log_id;
  END IF;

  BEGIN
    DROP TABLE IF EXISTS temp_batch;
    CREATE TEMP TABLE temp_batch ON COMMIT DROP AS
    SELECT r.*, r.ctid AS _src_ctid
    FROM public.rawprouni r
    WHERE r.ctid > COALESCE(p_after_ctid::tid, '(0,0)'::tid)
    ORDER BY r.ctid
    LIMIT p_limit;

    SELECT count(*) INTO v_batch_rows FROM temp_batch;
    SELECT _src_ctid INTO v_next_ctid FROM temp_batch ORDER BY _src_ctid DESC LIMIT 1;

    -- 1. Institutions
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT ON (r."CO_IES"::text) r."CO_IES"::text, r."NO_IES"
    FROM temp_batch r
    WHERE r."CO_IES" IS NOT NULL
    ORDER BY r."CO_IES"::text, r."NO_IES"
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Campus
    INSERT INTO public.campus (institution_id, external_code, name, city, state)
    SELECT DISTINCT ON (r."CO_CAMPUS"::text) i.id, r."CO_CAMPUS"::text, r."NO_CAMPUS",
      COALESCE(
        (SELECT c.name FROM public.cities c
         WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(r."NO_MUNICIPIO_CAMPUS"))
           AND c.state = r."SG_UF_CAMPUS" LIMIT 1),
        r."NO_MUNICIPIO_CAMPUS"
      ) AS city,
      r."SG_UF_CAMPUS"
    FROM temp_batch r
    JOIN public.institutions i ON i.external_code = r."CO_IES"::text
    WHERE r."CO_CAMPUS" IS NOT NULL
    ORDER BY r."CO_CAMPUS"::text, r."NO_CAMPUS"
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state;

    -- 3. Courses
    INSERT INTO public.courses (campus_id, course_code, course_name)
    SELECT DISTINCT ON (ca.id, r."CO_CURSO"::text) ca.id, r."CO_CURSO"::text, r."NO_CURSO"
    FROM temp_batch r
    JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
    WHERE r."CO_CURSO" IS NOT NULL
    ORDER BY ca.id, r."CO_CURSO"::text, r."NO_CURSO"
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name;

    -- 4. Opportunities — 1 por (curso, turno, TIPO_BOLSA). cutoff_score sempre NULL (Card 2).
    WITH batched_raw AS (
      SELECT * FROM temp_batch
    ),
    mapped_raw AS (
      SELECT
        c.id AS course_id,
        v_semester AS semester,
        CASE WHEN COALESCE(r."NO_TURNO", r."CO_TURNO") ILIKE 'Curso a dist%' THEN 'EaD'
             ELSE COALESCE(r."NO_TURNO", r."CO_TURNO") END AS shift,
        r."DS_TIPO_BOLSA" AS scholarship_type,
        v_year AS year,
        'prouni'::text AS opportunity_type,
        NULL::numeric AS cutoff_score,          -- Card 2: ProUni sem nota de corte
        (to_jsonb(r) - '_src_ctid') AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, year, semester, shift, scholarship_type)
        course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data
      FROM mapped_raw
      ORDER BY course_id, year, semester, shift, scholarship_type, cutoff_score DESC NULLS LAST
    ),
    updated AS (
      UPDATE public.opportunities o
      SET cutoff_score = m.cutoff_score, raw_data = m.raw_data, scholarship_type = m.scholarship_type, updated_at = now()
      FROM mapped m
      WHERE o.course_id = m.course_id
        AND o.opportunity_type = m.opportunity_type
        AND o.year = m.year
        AND o.semester = m.semester
        AND o.shift = m.shift
        AND o.scholarship_type IS NOT DISTINCT FROM m.scholarship_type   -- grão com tipo de bolsa
        AND o.concurrency_type IS NULL
      RETURNING o.id
    ),
    inserted AS (
      INSERT INTO public.opportunities (course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data)
      SELECT m.course_id, m.semester, m.shift, m.scholarship_type, m.year, m.opportunity_type, m.cutoff_score, m.raw_data
      FROM mapped m
      WHERE NOT EXISTS (
        SELECT 1 FROM public.opportunities o
        WHERE o.course_id = m.course_id
          AND o.opportunity_type = m.opportunity_type
          AND o.year = m.year
          AND o.semester = m.semester
          AND o.shift = m.shift
          AND o.scholarship_type IS NOT DISTINCT FROM m.scholarship_type -- grão com tipo de bolsa
          AND o.concurrency_type IS NULL
      )
      RETURNING id
    )
    SELECT count(*) INTO v_total_processed_in_log FROM inserted;

    -- 5. ProUni Vacancies — casa por (curso, turno, TIPO_BOLSA) para não somar tipos distintos
    WITH batched_raw AS (
      SELECT * FROM temp_batch
    ),
    vacancies_agg AS (
      SELECT
        o.id AS opportunity_id,
        -- MAX, não SUM: no CSV do MEC, BOLSAS_COTA_* trazem o TOTAL do grupo repetido em
        -- cada linha de cota (PPI/PCD, às vezes duplicadas) — SUM dobrava/quadruplicava.
        -- Verificado em 100% dos 72.336 grupos do Relatorio 2025.2.
        MAX(COALESCE(NULLIF(TRIM(r."BOLSAS_AMPLA_OFERTADA"), ''), '0')::integer) AS bolsas_ampla_ofertada,
        MAX(COALESCE(NULLIF(TRIM(r."BOLSAS_COTA_OFERTADA"), ''), '0')::integer) AS bolsas_cota_ofertada,
        MAX(COALESCE(NULLIF(TRIM(r."BOLSAS_AMPLA_OCUPADA"), ''), '0')::integer) AS bolsas_ampla_ocupada,
        MAX(COALESCE(NULLIF(TRIM(r."BOLSAS_COTA_OCUPADA"), ''), '0')::integer) AS bolsas_cota_ocupada
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
      JOIN public.opportunities o ON o.course_id = c.id
        AND o.opportunity_type = 'prouni'
        AND o.year = v_year
        AND o.semester = v_semester
        AND o.shift = CASE WHEN COALESCE(r."NO_TURNO", r."CO_TURNO") ILIKE 'Curso a dist%' THEN 'EaD'
                           ELSE COALESCE(r."NO_TURNO", r."CO_TURNO") END
        AND o.scholarship_type = r."DS_TIPO_BOLSA"    -- grão com tipo de bolsa
        AND o.concurrency_type IS NULL
      GROUP BY o.id
    )
    INSERT INTO public.opportunities_prouni_vacancies (
      opportunity_id,
      bolsas_ampla_ofertada, bolsas_cota_ofertada,
      bolsas_ampla_ocupada, bolsas_cota_ocupada
    )
    SELECT
      va.opportunity_id,
      va.bolsas_ampla_ofertada, va.bolsas_cota_ofertada,
      va.bolsas_ampla_ocupada, va.bolsas_cota_ocupada
    FROM vacancies_agg va
    ON CONFLICT (opportunity_id)
    DO UPDATE SET
      bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada,
      bolsas_cota_ofertada = EXCLUDED.bolsas_cota_ofertada,
      bolsas_ampla_ocupada = EXCLUDED.bolsas_ampla_ocupada,
      bolsas_cota_ocupada = EXCLUDED.bolsas_cota_ocupada,
      updated_at = now();

    v_processed := v_batch_rows;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_batch_rows >= p_limit THEN v_has_more := TRUE; END IF;
  IF v_batch_rows = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs
  SET records_processed = COALESCE(records_processed, 0) + v_processed
  WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    UPDATE public.opportunities
    SET scholarship_tags = '[["BOLSA_INTEGRAL"]]'::jsonb
    WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
      AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
      AND (UPPER(scholarship_type) LIKE '%INTEGRAL%' OR UPPER(scholarship_type) = 'BOLSA INTEGRAL');

    UPDATE public.opportunities
    SET scholarship_tags = '[["BOLSA_PARCIAL"]]'::jsonb
    WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
      AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
      AND (UPPER(scholarship_type) LIKE '%PARCIAL%' OR UPPER(scholarship_type) LIKE '%50%' OR UPPER(scholarship_type) = 'BOLSA PARCIAL 50%');

    SELECT COUNT(DISTINCT "CO_IES") INTO v_inst_count FROM public.rawprouni WHERE "CO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT "CO_CAMPUS") INTO v_campus_count FROM public.rawprouni WHERE "CO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT "CO_CURSO") INTO v_course_count FROM public.rawprouni WHERE "CO_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';
    SELECT COUNT(*) INTO v_opp_integral FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_INTEGRAL%';
    SELECT COUNT(*) INTO v_opp_parcial FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_PARCIAL%';
    SELECT COUNT(*) INTO v_opp_with_cutoff FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND cutoff_score IS NOT NULL;
    SELECT COUNT(*) INTO v_vacancies_count
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';
    SELECT COALESCE(SUM(pv.bolsas_ampla_ofertada), 0), COALESCE(SUM(pv.bolsas_cota_ofertada), 0),
           COALESCE(SUM(pv.bolsas_ampla_ocupada), 0), COALESCE(SUM(pv.bolsas_cota_ocupada), 0)
    INTO v_ampla_ofertada, v_cota_ofertada, v_ampla_ocupada, v_cota_ocupada
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

    IF v_errors IS NULL THEN
      v_detail_msg := 'ProUni importado com sucesso (pipeline unificado).' || chr(10)
        || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10)
        || '• IES distintas:                  ' || v_inst_count || chr(10)
        || '• Campus distintos:               ' || v_campus_count || chr(10)
        || '• Cursos distintos:               ' || v_course_count || chr(10)
        || '• Oportunidades no ciclo:         ' || v_opp_count || chr(10)
        || '• Bolsas integrais:               ' || v_opp_integral || chr(10)
        || '• Bolsas parciais:                ' || v_opp_parcial || chr(10)
        || '• Opps. com nota de corte:        ' || v_opp_with_cutoff || chr(10)
        || '• Registros vagas ProUni:         ' || v_vacancies_count || chr(10)
        || '• Bolsas ampla ofertada:          ' || v_ampla_ofertada || chr(10)
        || '• Bolsas cota ofertada:           ' || v_cota_ofertada || chr(10)
        || '• Bolsas ampla ocupada:           ' || v_ampla_ocupada || chr(10)
        || '• Bolsas cota ocupada:            ' || v_cota_ocupada;

      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
      TRUNCATE TABLE public.rawprouni;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  ELSIF v_errors IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    v_has_more := FALSE;
  END IF;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'has_more', v_has_more,
    'log_id', v_log_id,
    'next_cursor', v_next_ctid::text,
    'total_raw_rows', v_raw_count,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );

EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."etl_import_prouni"("p_program_id" "uuid", "p_limit" integer, "p_after_ctid" "text", "p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_refresh_opportunities"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $$
DECLARE
  v_log_id UUID;
  v_errors TEXT;
  v_processed INTEGER := 0;
  v_cycles TEXT;
  
  v_opps_count INTEGER := 0;
  v_inst_count INTEGER := 0;
  v_campus_count INTEGER := 0;
  v_details TEXT;
BEGIN
  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_opportunities', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;
    
    -- Contar registros pós-refresh
    SELECT count(*) INTO v_processed FROM public.v_unified_opportunities;
    v_opps_count := v_processed;
    
    SELECT count(*) INTO v_inst_count FROM public.v_unified_institutions;
    
    SELECT count(DISTINCT c.campus_id) INTO v_campus_count
    FROM public.opportunities o
    JOIN public.programs p ON p.cycle_year = o.year AND p.cycle_semester = o.semester AND p.type = o.opportunity_type
    JOIN public.courses c ON c.id = o.course_id
    WHERE p.status IN ('incoming', 'opened', 'closed');
    
    -- Listar ciclos ativos sincronizados
    SELECT string_agg(title || ' (' || status || ')', ', ')
    INTO v_cycles
    FROM public.programs 
    WHERE status != 'inactive';
    
    v_details := 'Ciclos Sincronizados: ' || COALESCE(v_cycles, 'Nenhum') || E'\n' ||
                 'Oportunidades (Cursos): ' || v_opps_count || E'\n' ||
                 'Câmpus: ' || COALESCE(v_campus_count, 0) || E'\n' ||
                 'Instituições: ' || v_inst_count;
                 
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs 
    SET status = 'success', 
        records_processed = v_processed, 
        errors = v_details,
        finished_at = now() 
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs 
    SET status = 'error', 
        errors = v_errors, 
        finished_at = now() 
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."etl_import_refresh_opportunities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_inst_id           UUID;
  v_campus_id         UUID;
  v_course_id         UUID;
  -- Rich logging counters
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_opp_with_cutoff   INTEGER;
  v_opp_no_cutoff     INTEGER;
  v_detail_msg        TEXT;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu', 'running', now())
  RETURNING id INTO v_log_id;

  -- STEP 1: institutions
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS external_code, "NO_IES" AS name
    FROM public.rawsisu
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- STEP 2: institutions_info_sisu
  FOR v_rec IN
    SELECT DISTINCT ON ("CO_IES")
      "CO_IES"::text AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM public.rawsisu
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (institution_id, acronym, academic_organization, administrative_category)
        VALUES (v_inst_id, v_rec.acronym, v_rec.academic_organization, v_rec.administrative_category)
        ON CONFLICT (institution_id) DO UPDATE SET
          acronym = EXCLUDED.acronym,
          academic_organization = EXCLUDED.academic_organization,
          administrative_category = EXCLUDED.administrative_category,
          updated_at = now();
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- STEP 3: campus
  FOR v_rec IN
    SELECT DISTINCT
      "CO_IES"::text AS inst_external_code,
      "NO_CAMPUS" AS name,
      "NO_MUNICIPIO_CAMPUS" AS municipio,
      "SG_UF_CAMPUS" AS state,
      "DS_REGIAO_CAMPUS" AS region
    FROM public.rawsisu
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id,
          v_rec.name,
          COALESCE(
            (SELECT c.name FROM public.cities c
             WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio))
               AND c.state = v_rec.state LIMIT 1),
            v_rec.municipio
          ),
          v_rec.state,
          v_rec.region
        )
        ON CONFLICT (institution_id, name, city) DO UPDATE SET
          state = EXCLUDED.state,
          region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- STEP 4: courses
  FOR v_rec IN
    SELECT DISTINCT
      "CO_IES"::text AS inst_external_code,
      "NO_CAMPUS" AS campus_name,
      "CO_IES_CURSO"::text AS course_code,
      "NO_CURSO" AS course_name,
      "DS_GRAU" AS degree_type
    FROM public.rawsisu
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id
      FROM public.campus ca
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
      LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name, v_rec.degree_type)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET
          course_name = EXCLUDED.course_name,
          degree_type = EXCLUDED.degree_type;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- STEP 5: opportunities — now with concurrency_type in the conflict key
  -- Each row in rawsisu = one unique opportunity (course + shift + modality)
  FOR v_rec IN
    SELECT
      "CO_IES"::text AS inst_external_code,
      "NO_CAMPUS" AS campus_name,
      "CO_IES_CURSO"::text AS course_code,
      "DS_TURNO" AS shift,
      "DS_MOD_CONCORRENCIA" AS concurrency_type,
      "NU_NOTACORTE" AS raw_cutoff,
      "QT_INSCRICAO" AS qt_inscricao,
      s
    FROM public.rawsisu s
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
        AND c.course_code = v_rec.course_code
      LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.opportunities (
          course_id,
          semester,
          shift,
          concurrency_type,
          concurrency_tags,
          year,
          opportunity_type,
          cutoff_score,
          raw_data
        )
        VALUES (
          v_course_id,
          v_semester,
          v_rec.shift,
          v_rec.concurrency_type,
          (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1),
          v_year,
          'sisu',
          CASE
            WHEN v_rec.raw_cutoff IS NULL OR TRIM(v_rec.raw_cutoff) = '' THEN NULL
            ELSE REPLACE(REPLACE(TRIM(v_rec.raw_cutoff), '.', ''), ',', '.')::numeric
          END,
          to_jsonb(v_rec.s)
        )
        -- Matches the partial unique index uq_opportunities_sisu
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type)
        WHERE concurrency_type IS NOT NULL
        DO UPDATE SET
          cutoff_score     = EXCLUDED.cutoff_score,
          concurrency_tags = EXCLUDED.concurrency_tags,
          raw_data         = EXCLUDED.raw_data,
          updated_at       = now();

        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- ── Rich post-run stats ──────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisu;
  SELECT COUNT(DISTINCT "CO_IES") INTO v_inst_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL;
  SELECT COUNT(DISTINCT ("CO_IES"::text || '|' || "NO_CAMPUS")) INTO v_campus_count
    FROM public.rawsisu WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL;
  SELECT COUNT(DISTINCT "CO_IES_CURSO") INTO v_course_count
    FROM public.rawsisu WHERE "CO_IES_CURSO" IS NOT NULL;

  SELECT COUNT(*) INTO v_opp_count
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

  SELECT COUNT(*) INTO v_opp_with_cutoff
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu' AND cutoff_score IS NOT NULL;

  v_opp_no_cutoff := v_opp_count - v_opp_with_cutoff;

  IF v_errors IS NULL THEN
    v_detail_msg :=
      'Base Consolidada importada com sucesso.' ||
      chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count ||
      chr(10) || '• IES distintas:                  ' || v_inst_count ||
      chr(10) || '• Campus distintos:               ' || v_campus_count ||
      chr(10) || '• Cursos distintos:               ' || v_course_count ||
      chr(10) || '• Oportunidades processadas:      ' || v_processed ||
      chr(10) || '• Opps. validadas com nota:       ' || v_opp_with_cutoff ||
      chr(10) || '• Opps. criadas p/ falta de match:' || (v_opp_count - v_processed);

    UPDATE public.etl_run_logs
    SET status = 'success',
        records_processed = v_processed,
        errors = v_detail_msg,
        finished_at = now()
    WHERE id = v_log_id;

    -- Clear raw table to free space and prevent accidental re-runs
    TRUNCATE TABLE public.rawsisu;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object(
    'opportunities_processed', v_processed,
    'institutions', v_inst_count,
    'campus', v_campus_count,
    'courses', v_course_count,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid", "p_limit" integer DEFAULT NULL::integer, "p_offset" integer DEFAULT 0, "p_log_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
  v_batch_rows        INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisu;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  BEGIN
    -- 1. Insert institutions using CO_IES (clean dots if any)
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT replace(r."CO_IES", '.', '') as external_code, r."NO_IES" 
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    WHERE r."CO_IES" IS NOT NULL AND replace(r."CO_IES", '.', '') <> ''
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Insert campus using unique constraint (institution_id, name, city)
    INSERT INTO public.campus (institution_id, name, city, state, region)
    SELECT DISTINCT i.id, r."NO_CAMPUS", 
      COALESCE(
        (SELECT c.name FROM public.cities c
         WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(r."NO_MUNICIPIO_CAMPUS"))
           AND c.state = r."SG_UF_CAMPUS" LIMIT 1),
        r."NO_MUNICIPIO_CAMPUS"
      ) as city,
      r."SG_UF_CAMPUS",
      r."DS_REGIAO_CAMPUS"
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
    WHERE r."NO_CAMPUS" IS NOT NULL
    ON CONFLICT (institution_id, name, city) DO UPDATE SET state = EXCLUDED.state, region = EXCLUDED.region;

    -- 3. Insert courses using (campus_id, course_code) unique constraint
    INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
    SELECT DISTINCT ca.id, replace(r."CO_IES_CURSO", '.', '') as course_code, r."NO_CURSO", r."DS_GRAU"
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
    JOIN public.campus ca ON ca.institution_id = i.id AND ca.name = r."NO_CAMPUS"
    WHERE r."CO_IES_CURSO" IS NOT NULL AND replace(r."CO_IES_CURSO", '.', '') <> ''
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;

    -- 4. Bulk Upsert Opportunities & update Vacancies records
    WITH batched_raw AS (
      SELECT * FROM public.rawsisu 
      ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" 
      LIMIT p_limit OFFSET p_offset
    ),
    mapped_raw AS (
      SELECT 
        c.id AS course_id, 
        v_semester AS semester, 
        r."DS_TURNO" AS shift, 
        r."DS_MOD_CONCORRENCIA" AS concurrency_type,
        (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = r."DS_MOD_CONCORRENCIA" LIMIT 1) AS concurrency_tags,
        v_year AS year, 
        'sisu'::text AS opportunity_type,
        CASE 
          WHEN r."NU_NOTACORTE" IS NULL OR TRIM(r."NU_NOTACORTE") = '' THEN NULL 
          ELSE REPLACE(REPLACE(TRIM(r."NU_NOTACORTE"), '.', ''), ',', '.')::numeric 
        END AS cutoff_score,
        replace(r."QT_INSCRICAO", '.', '') AS qt_inscricao,
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
      JOIN public.campus ca ON ca.institution_id = i.id AND ca.name = r."NO_CAMPUS"
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = replace(r."CO_IES_CURSO", '.', '')
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift, concurrency_type) * 
      FROM mapped_raw 
      ORDER BY course_id, opportunity_type, year, semester, shift, concurrency_type, cutoff_score DESC
    ),
    upserted AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data
      )
      SELECT course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data
      FROM mapped
      ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) 
      WHERE concurrency_type IS NOT NULL
      DO UPDATE SET
        cutoff_score = EXCLUDED.cutoff_score,
        concurrency_tags = EXCLUDED.concurrency_tags,
        raw_data = EXCLUDED.raw_data,
        updated_at = now()
      RETURNING id, course_id, shift, concurrency_type
    ),
    updated_vacancies AS (
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = m.qt_inscricao, updated_at = now()
      FROM upserted u
      JOIN mapped m ON m.course_id = u.course_id AND m.shift = u.shift AND m.concurrency_type = u.concurrency_type
      WHERE sv.opportunity_id = u.id AND m.qt_inscricao IS NOT NULL
      RETURNING sv.opportunity_id
    )
    SELECT (SELECT count(*) FROM mapped_raw) INTO v_processed;
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF p_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_batch_rows FROM (
      SELECT 1 FROM public.rawsisu LIMIT p_limit OFFSET p_offset
    ) sub;
    v_has_more := (v_batch_rows = p_limit);
  ELSE
    v_has_more := FALSE;
  END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    SELECT COUNT(DISTINCT replace("CO_IES", '.', '')) INTO v_inst_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT (replace("CO_IES", '.', '') || '|' || "NO_CAMPUS")) INTO v_campus_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT replace("CO_IES_CURSO", '.', '')) INTO v_course_count FROM public.rawsisu WHERE "CO_IES_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

    IF v_errors IS NULL THEN
      v_detail_msg := 'Sisu importado com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• IES distintas no arquivo:       ' || v_inst_count || chr(10) || '• Campus distintos:               ' || v_campus_count || chr(10) || '• Cursos distintos:               ' || v_course_count || chr(10) || '• Oportunidades no ciclo:         ' || v_opp_count;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisu;
      
      -- Mark program as fully imported
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
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


ALTER FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "statement_timeout" TO '10min'
    AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_inst_id           UUID;
  v_campus_id         UUID;
  v_course_id         UUID;
  v_opp_id            UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_vacancies_in_db   INTEGER;
  v_opps_with_vaga    INTEGER;
  v_opps_without_vaga INTEGER;
  v_opps_total        INTEGER;
  v_historical_prop   INTEGER;
  v_detail_msg        TEXT;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 1: Institutions
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT replace("CO_IES", '.', '') AS external_code, "NO_IES" AS name
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> ''
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'IES: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 2: Institutions Info
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT ON (replace("CO_IES", '.', ''))
      replace("CO_IES", '.', '') AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> ''
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (institution_id, acronym, academic_organization, administrative_category)
        VALUES (v_inst_id, v_rec.acronym, v_rec.academic_organization, v_rec.administrative_category)
        ON CONFLICT (institution_id) DO UPDATE SET
          acronym = EXCLUDED.acronym,
          academic_organization = EXCLUDED.academic_organization,
          administrative_category = EXCLUDED.administrative_category,
          updated_at = now();
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Info: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 3: Campus
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT
      replace("CO_IES", '.', '') AS inst_external_code,
      "NO_CAMPUS" AS name,
      "NO_MUNICIPIO_CAMPUS" AS municipio,
      "SG_UF_CAMPUS" AS state,
      "DS_REGIAO" AS region
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> '' AND "NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id,
          v_rec.name,
          COALESCE(
            (SELECT c.name FROM public.cities c
             WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio))
               AND c.state = v_rec.state LIMIT 1),
            v_rec.municipio
          ),
          v_rec.state,
          v_rec.region
        )
        ON CONFLICT (institution_id, name, city) DO UPDATE SET
          state = EXCLUDED.state,
          region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Campus: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 4: Courses
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT
      replace("CO_IES", '.', '') AS inst_external_code,
      "NO_CAMPUS" AS campus_name,
      replace("CO_IES_CURSO", '.', '') AS course_code,
      "NO_CURSO" AS course_name,
      "DS_GRAU" AS degree_type
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> '' 
      AND "NO_CAMPUS" IS NOT NULL 
      AND "CO_IES_CURSO" IS NOT NULL AND replace("CO_IES_CURSO", '.', '') <> ''
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id
      FROM public.campus ca
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
      LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name, v_rec.degree_type)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET
          course_name = EXCLUDED.course_name,
          degree_type = EXCLUDED.degree_type;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Course: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 5: Opportunities & Vacancies
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT
      replace("CO_IES", '.', '')            AS inst_external_code,
      "NO_CAMPUS"               AS campus_name,
      replace("CO_IES_CURSO", '.', '')      AS course_code,
      "DS_TURNO"                AS shift,
      "DS_MOD_CONCORRENCIA"     AS concurrency_type,
      *
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> '' 
      AND "NO_CAMPUS" IS NOT NULL 
      AND "CO_IES_CURSO" IS NOT NULL AND replace("CO_IES_CURSO", '.', '') <> ''
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name         = v_rec.campus_name
        AND c.course_code   = v_rec.course_code
      LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        
        -- Create or update Opportunity (Without cutoff_score, as it comes from Base)
        INSERT INTO public.opportunities (
          course_id,
          semester,
          shift,
          concurrency_type,
          concurrency_tags,
          year,
          opportunity_type,
          cutoff_score,
          raw_data
        )
        VALUES (
          v_course_id,
          v_semester,
          v_rec.shift,
          v_rec.concurrency_type,
          (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1),
          v_year,
          'sisu',
          NULL, -- No cutoff score in vacancies file
          '{}'::jsonb
        )
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type)
        WHERE concurrency_type IS NOT NULL
        DO UPDATE SET
          concurrency_tags = EXCLUDED.concurrency_tags,
          updated_at       = now()
        RETURNING id INTO v_opp_id;

        -- Create or update Vacancies
        IF v_opp_id IS NOT NULL THEN
          INSERT INTO public.opportunities_sisu_vacancies (
            opportunity_id,
            qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas,
            nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia,
            peso_redacao, nota_minima_redacao,
            peso_linguagens, nota_minima_linguagens,
            peso_matematica, nota_minima_matematica,
            peso_ciencias_humanas, nota_minima_ciencias_humanas,
            peso_ciencias_natureza, nota_minima_ciencias_natureza,
            nu_media_minima_enem,
            perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd,
            nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd
          )
          VALUES (
            v_opp_id,
            v_rec."QT_SEMESTRE",
            v_rec."NU_VAGAS_AUTORIZADAS",
            v_rec."QT_VAGAS_OFERTADAS",
            v_rec."NU_PERCENTUAL_BONUS",
            v_rec."TP_MOD_CONCORRENCIA",
            v_rec."TP_COTA",
            v_rec."DS_MOD_CONCORRENCIA",
            COALESCE(NULLIF(REPLACE(v_rec."PESO_REDACAO",           ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_REDACAO",    ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_LINGUAGENS",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_LINGUAGENS", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_MATEMATICA",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_MATEMATICA", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_HUMANAS",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_NATUREZA",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NU_MEDIA_MINIMA_ENEM",  ',', '.'), ''), '0')::numeric,
            v_rec."PERC_UF_IBGE_PPI",
            v_rec."PERC_UF_IBGE_PP",
            v_rec."PERC_UF_IBGE_I",
            v_rec."PERC_UF_IBGE_Q",
            v_rec."PERC_UF_IBGE_PCD",
            v_rec."NU_PERC_LEI",
            v_rec."NU_PERC_PPI",
            v_rec."NU_PERC_PP",
            v_rec."NU_PERC_I",
            v_rec."NU_PERC_Q",
            v_rec."NU_PERC_PCD"
          )
          ON CONFLICT (opportunity_id)
          DO UPDATE SET
            qt_semestre                   = EXCLUDED.qt_semestre,
            nu_vagas_autorizadas          = EXCLUDED.nu_vagas_autorizadas,
            qt_vagas_ofertadas            = EXCLUDED.qt_vagas_ofertadas,
            nu_percentual_bonus           = EXCLUDED.nu_percentual_bonus,
            tp_mod_concorrencia           = EXCLUDED.tp_mod_concorrencia,
            tp_cota                       = EXCLUDED.tp_cota,
            ds_mod_concorrencia           = EXCLUDED.ds_mod_concorrencia,
            peso_redacao                  = EXCLUDED.peso_redacao,
            nota_minima_redacao           = EXCLUDED.nota_minima_redacao,
            peso_linguagens               = EXCLUDED.peso_linguagens,
            nota_minima_linguagens        = EXCLUDED.nota_minima_linguagens,
            peso_matematica               = EXCLUDED.peso_matematica,
            nota_minima_matematica        = EXCLUDED.nota_minima_matematica,
            peso_ciencias_humanas         = EXCLUDED.peso_ciencias_humanas,
            nota_minima_ciencias_humanas  = EXCLUDED.nota_minima_ciencias_humanas,
            peso_ciencias_natureza        = EXCLUDED.peso_ciencias_natureza,
            nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza,
            nu_media_minima_enem          = EXCLUDED.nu_media_minima_enem,
            updated_at                    = now();

          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Opp/Vaga: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Historical propagation (previous year -> current year)
  BEGIN
    -- cutoff_score
    UPDATE public.opportunities op_curr
    SET cutoff_score = op_prev.cutoff_score
    FROM public.opportunities op_prev
    WHERE op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester
      AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_year - 1 AND op_prev.semester = v_semester
      AND op_curr.course_id        = op_prev.course_id
      AND op_curr.shift            = op_prev.shift
      AND op_curr.concurrency_type = op_prev.concurrency_type
      AND op_prev.cutoff_score IS NOT NULL
      AND op_curr.cutoff_score IS NULL;

    -- historic vacancies
    UPDATE public.opportunities_sisu_vacancies osv_curr
    SET vagas_ociosas_prev      = osv_prev.vagas_ociosas_prev,
        qt_inscricao_prev       = osv_prev.qt_inscricao_prev,
        qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas
    FROM public.opportunities o_curr
    JOIN public.opportunities o_prev
      ON o_prev.course_id       = o_curr.course_id
     AND o_prev.shift           = o_curr.shift
     AND o_prev.concurrency_type = o_curr.concurrency_type
     AND o_prev.year            = v_year - 1
     AND o_prev.semester        = v_semester
     AND o_prev.opportunity_type = 'sisu'
    JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
    WHERE osv_curr.opportunity_id = o_curr.id
      AND o_curr.year             = v_year
      AND o_curr.semester         = v_semester
      AND o_curr.opportunity_type = 'sisu';

    GET DIAGNOSTICS v_historical_prop = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    v_historical_prop := 0;
    v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Propagation: ' || SQLERRM, 1500);
  END;

  -- ── Rich post-run stats ──────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisuvacancies;
  v_skipped := v_raw_count - v_processed;

  SELECT COUNT(*) INTO v_vacancies_in_db
  FROM public.opportunities_sisu_vacancies osv
  JOIN public.opportunities o ON o.id = osv.opportunity_id
  WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

  SELECT COUNT(*) INTO v_opps_total
  FROM public.opportunities
  WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

  SELECT COUNT(DISTINCT o.id) INTO v_opps_with_vaga
  FROM public.opportunities o
  JOIN public.opportunities_sisu_vacancies osv ON osv.opportunity_id = o.id
  WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

  v_opps_without_vaga := v_opps_total - v_opps_with_vaga;

  IF v_errors IS NULL THEN
    v_detail_msg :=
      'Vagas SiSU importadas com sucesso.' ||
      chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count ||
      chr(10) || '• Vagas vinculadas (mapeadas):    ' || v_processed ||
      chr(10) || '• Linhas ignoradas (s/ opp.):     ' || v_skipped ||
      chr(10) || '• Registros em sisu_vacancies:    ' || v_vacancies_in_db ||
      chr(10) || '• Oportunidades c/ vaga:          ' || v_opps_with_vaga || ' / ' || v_opps_total ||
      chr(10) || '• Oportunidades s/ vaga:          ' || v_opps_without_vaga ||
      chr(10) || '• Vagas c/ histórico propagado:   ' || COALESCE(v_historical_prop, 0);

    UPDATE public.etl_run_logs
    SET status = 'success',
        records_processed = v_processed,
        errors = v_detail_msg,
        finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object(
    'vacancies_processed', v_processed,
    'vacancies_in_db', v_vacancies_in_db,
    'opps_with_vaga', v_opps_with_vaga,
    'opps_without_vaga', v_opps_without_vaga,
    'historical_propagated', v_historical_prop,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = LEFT(SQLERRM, 1500), finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid", "p_limit" integer DEFAULT NULL::integer, "p_offset" integer DEFAULT 0, "p_log_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_prev_year         INTEGER;
  v_prev_semester     TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_inst_id           UUID;
  v_campus_id         UUID;
  v_course_id         UUID;
  v_opp_id            UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_vacancies_in_db   INTEGER;
  v_opps_with_vaga    INTEGER;
  v_opps_without_vaga INTEGER;
  v_opps_total        INTEGER;
  v_historical_prop   INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
  v_batch_rows        INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  SELECT p_prev.cycle_year, p_prev.cycle_semester INTO v_prev_year, v_prev_semester
  FROM public.programs p_prev
  WHERE p_prev.id = (SELECT prev_program_id FROM public.programs WHERE id = p_program_id);

  IF v_prev_year IS NULL THEN
    v_prev_year := v_year - 1;
    v_prev_semester := v_semester;
  END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisuvacancies;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu_vacancies', 'running', now(), 0)
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  -- Institutions
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS external_code, "NO_IES" AS name
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'IES: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Institutions SISU info
  FOR v_rec IN
    SELECT DISTINCT ON ("CO_IES")
      "CO_IES"::text AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (institution_id, acronym, academic_organization, administrative_category)
        VALUES (v_inst_id, v_rec.acronym, v_rec.academic_organization, v_rec.administrative_category)
        ON CONFLICT (institution_id) DO UPDATE SET
          acronym = EXCLUDED.acronym, academic_organization = EXCLUDED.academic_organization, administrative_category = EXCLUDED.administrative_category, updated_at = now();
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Info: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Campus
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS name, "NO_MUNICIPIO_CAMPUS" AS municipio, "SG_UF_CAMPUS" AS state, "DS_REGIAO" AS region
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id, v_rec.name,
          COALESCE((SELECT c.name FROM public.cities c WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio)) AND c.state = v_rec.state LIMIT 1), v_rec.municipio),
          v_rec.state, v_rec.region
        ) ON CONFLICT (institution_id, name, city) DO UPDATE SET state = EXCLUDED.state, region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Campus: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Courses
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "NO_CURSO" AS course_name, "DS_GRAU" AS degree_type
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id FROM public.campus ca JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name, v_rec.degree_type)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Course: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Opportunities and vacancies
  FOR v_rec IN
    SELECT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "DS_TURNO" AS shift, "DS_MOD_CONCORRENCIA" AS concurrency_type, *
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name AND c.course_code = v_rec.course_code LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.opportunities (course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data)
        VALUES (v_course_id, v_semester, v_rec.shift, v_rec.concurrency_type, (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1), v_year, 'sisu', NULL, '{}'::jsonb)
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) WHERE concurrency_type IS NOT NULL
        DO UPDATE SET concurrency_tags = EXCLUDED.concurrency_tags, updated_at = now() RETURNING id INTO v_opp_id;

        IF v_opp_id IS NOT NULL THEN
          INSERT INTO public.opportunities_sisu_vacancies (opportunity_id, qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas, nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia, peso_redacao, nota_minima_redacao, peso_linguagens, nota_minima_linguagens, peso_matematica, nota_minima_matematica, peso_ciencias_humanas, nota_minima_ciencias_humanas, peso_ciencias_natureza, nota_minima_ciencias_natureza, nu_media_minima_enem, perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd, nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd)
          VALUES (v_opp_id, v_rec."QT_SEMESTRE", v_rec."NU_VAGAS_AUTORIZADAS", v_rec."QT_VAGAS_OFERTADAS", v_rec."NU_PERCENTUAL_BONUS", v_rec."TP_MOD_CONCORRENCIA", v_rec."TP_COTA", v_rec."DS_MOD_CONCORRENCIA", COALESCE(NULLIF(REPLACE(v_rec."PESO_REDACAO", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_REDACAO", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_LINGUAGENS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_LINGUAGENS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_MATEMATICA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_MATEMATICA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NU_MEDIA_MINIMA_ENEM", ',', '.'), ''), '0')::numeric, v_rec."PERC_UF_IBGE_PPI", v_rec."PERC_UF_IBGE_PP", v_rec."PERC_UF_IBGE_I", v_rec."PERC_UF_IBGE_Q", v_rec."PERC_UF_IBGE_PCD", v_rec."NU_PERC_LEI", v_rec."NU_PERC_PPI", v_rec."NU_PERC_PP", v_rec."NU_PERC_I", v_rec."NU_PERC_Q", v_rec."NU_PERC_PCD")
          ON CONFLICT (opportunity_id) DO UPDATE SET qt_semestre = EXCLUDED.qt_semestre, nu_vagas_autorizadas = EXCLUDED.nu_vagas_autorizadas, qt_vagas_ofertadas = EXCLUDED.qt_vagas_ofertadas, nu_percentual_bonus = EXCLUDED.nu_percentual_bonus, tp_mod_concorrencia = EXCLUDED.tp_mod_concorrencia, tp_cota = EXCLUDED.tp_cota, ds_mod_concorrencia = EXCLUDED.ds_mod_concorrencia, peso_redacao = EXCLUDED.peso_redacao, nota_minima_redacao = EXCLUDED.nota_minima_redacao, peso_linguagens = EXCLUDED.peso_linguagens, nota_minima_linguagens = EXCLUDED.nota_minima_linguagens, peso_matematica = EXCLUDED.peso_matematica, nota_minima_matematica = EXCLUDED.nota_minima_matematica, peso_ciencias_humanas = EXCLUDED.peso_ciencias_humanas, nota_minima_ciencias_humanas = EXCLUDED.nota_minima_ciencias_humanas, peso_ciencias_natureza = EXCLUDED.peso_ciencias_natureza, nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza, nu_media_minima_enem = EXCLUDED.nu_media_minima_enem, updated_at = now();

          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Opp/Vaga: ' || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_batch_rows FROM (
      SELECT 1 FROM public.rawsisuvacancies LIMIT p_limit OFFSET p_offset
    ) sub;
    v_has_more := (v_batch_rows = p_limit);
  ELSE
    v_has_more := FALSE;
  END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    BEGIN
      -- Propagate cutoff_score from previous cycle (handling MEC data inconsistencies)
      UPDATE public.opportunities op_curr 
      SET cutoff_score = op_prev.cutoff_score 
      FROM public.opportunities op_prev
      JOIN public.courses c_prev ON c_prev.id = op_prev.course_id
      JOIN public.campus ca_prev ON ca_prev.id = c_prev.campus_id
      JOIN public.campus ca_curr ON ca_curr.institution_id = ca_prev.institution_id AND lower(public.f_unaccent(ca_curr.name)) = lower(public.f_unaccent(ca_prev.name))
      JOIN public.courses c_curr ON c_curr.campus_id = ca_curr.id AND lower(public.f_unaccent(c_curr.course_name)) = lower(public.f_unaccent(c_prev.course_name))
      WHERE op_curr.course_id = c_curr.id 
      AND op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester 
      AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_prev_year AND op_prev.semester = v_prev_semester 
      AND op_curr.shift = op_prev.shift 
      AND (
          op_curr.concurrency_type = op_prev.concurrency_type OR
          (op_curr.concurrency_tags IS NOT NULL AND op_prev.concurrency_tags IS NOT NULL AND 
           op_curr.concurrency_tags::text = op_prev.concurrency_tags::text)
      )
      AND op_prev.cutoff_score IS NOT NULL AND op_curr.cutoff_score IS NULL;

      -- qt_vagas_ofertadas_prev propagation (handling MEC data inconsistencies)
      UPDATE public.opportunities_sisu_vacancies osv_curr
      SET qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas
      FROM public.opportunities o_curr
      JOIN public.courses c_curr ON c_curr.id = o_curr.course_id
      JOIN public.campus ca_curr ON ca_curr.id = c_curr.campus_id
      JOIN public.courses c_prev ON lower(public.f_unaccent(c_prev.course_name)) = lower(public.f_unaccent(c_curr.course_name))
      JOIN public.campus ca_prev ON ca_prev.id = c_prev.campus_id AND ca_prev.institution_id = ca_curr.institution_id AND lower(public.f_unaccent(ca_prev.name)) = lower(public.f_unaccent(ca_curr.name))
      JOIN public.opportunities o_prev ON o_prev.course_id = c_prev.id AND o_prev.shift = o_curr.shift AND (o_curr.concurrency_type = o_prev.concurrency_type OR (o_curr.concurrency_tags IS NOT NULL AND o_prev.concurrency_tags IS NOT NULL AND o_curr.concurrency_tags::text = o_prev.concurrency_tags::text)) AND o_prev.year = v_prev_year AND o_prev.semester = v_prev_semester AND o_prev.opportunity_type = 'sisu'
      JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
      WHERE osv_curr.opportunity_id = o_curr.id AND o_curr.year = v_year AND o_curr.semester = v_semester AND o_curr.opportunity_type = 'sisu';

      GET DIAGNOSTICS v_historical_prop = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_historical_prop := 0; v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Propagation: ' || SQLERRM, 1500);
    END;

    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_vacancies_in_db FROM public.opportunities_sisu_vacancies osv JOIN public.opportunities o ON o.id = osv.opportunity_id WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
    SELECT COUNT(*) INTO v_opps_total FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';
    SELECT COUNT(DISTINCT o.id) INTO v_opps_with_vaga FROM public.opportunities o JOIN public.opportunities_sisu_vacancies osv ON osv.opportunity_id = o.id WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
    v_opps_without_vaga := v_opps_total - v_opps_with_vaga;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Vagas SiSU importadas com sucesso.' || chr(10)
        || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10)
        || '• Vagas vinculadas (mapeadas):    ' || v_total_processed_in_log || chr(10)
        || '• Linhas ignoradas (s/ opp.):     ' || v_skipped || chr(10)
        || '• Registros em sisu_vacancies:    ' || v_vacancies_in_db || chr(10)
        || '• Oportunidades c/ vaga:          ' || v_opps_with_vaga || ' / ' || v_opps_total || chr(10)
        || '• Oportunidades s/ vaga:          ' || v_opps_without_vaga || chr(10)
        || '• Vagas c/ histórico propagado:   ' || COALESCE(v_historical_prop, 0);
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisuvacancies;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('vacancies_processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = LEFT(SQLERRM, 1500), finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_reap_stale_runs"("p_max_age" interval DEFAULT '00:15:00'::interval) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_reaped integer;
BEGIN
  UPDATE public.etl_run_logs
  SET status = 'error',
      errors = 'Execução expirada (perda de conexão ou navegador fechado durante o processamento).',
      finished_at = now()
  WHERE status = 'running'
    AND started_at < now() - p_max_age;
  GET DIAGNOSTICS v_reaped = ROW_COUNT;
  RETURN v_reaped;
END;
$$;


ALTER FUNCTION "public"."etl_reap_stale_runs"("p_max_age" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_rollback_log"("p_log_id" "uuid", "p_limit" integer DEFAULT 500, "p_active_rollback_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_program_id uuid;
  v_etl_type text;
  v_status text;
  v_year integer;
  v_semester text;
  v_new_log_id uuid;
  v_new_etl_type text;
  v_detail_msg text;

  v_opps_deleted integer := 0;
  v_vacancies_deleted integer := 0;
  v_prouni_vac_deleted integer := 0;
  v_sisu_vac_updated integer := 0;

  v_has_more boolean := false;
  v_total_processed integer := 0;
BEGIN
  SET LOCAL statement_timeout = '10min';

  SELECT program_id, etl_type, status INTO v_program_id, v_etl_type, v_status
  FROM public.etl_run_logs WHERE id = p_log_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Log not found';
  END IF;

  IF v_status = 'running' THEN
    RAISE EXCEPTION 'Cannot rollback a running ETL operation';
  END IF;

  IF v_etl_type LIKE 'rollback_%' THEN
    RAISE EXCEPTION 'Cannot rollback a rollback operation';
  END IF;

  -- Guard: never mutate a cycle that has another import/rollback in flight.
  IF v_program_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.etl_run_logs
    WHERE program_id = v_program_id
      AND status = 'running'
      AND id <> COALESCE(p_active_rollback_id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) THEN
    RAISE EXCEPTION 'Há outra execução em andamento para este ciclo. Aguarde antes de fazer rollback.';
  END IF;

  v_new_etl_type := 'rollback_' || v_etl_type;

  IF p_active_rollback_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (v_program_id, v_new_etl_type, 'running', now(), 0)
    RETURNING id INTO v_new_log_id;
  ELSE
    v_new_log_id := p_active_rollback_id;
  END IF;

  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;

    UPDATE public.programs SET is_fully_imported = false WHERE id = v_program_id;
  END IF;

  BEGIN
    IF v_etl_type = 'sisu_vacancies' THEN
      DELETE FROM public.opportunities_sisu_vacancies sv
      WHERE sv.ctid IN (
        SELECT sv_inner.ctid FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_vacancies_deleted = ROW_COUNT;

      IF v_vacancies_deleted < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'sisu'
          LIMIT (p_limit - v_vacancies_deleted)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_vacancies_deleted + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'sisu' THEN
      WITH to_update AS (
        SELECT sv_inner.opportunity_id, sv_inner.tp_mod_concorrencia
        FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
          AND sv_inner.qt_inscricao IS NOT NULL
        LIMIT p_limit
      )
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = NULL, updated_at = now()
      FROM to_update
      WHERE sv.opportunity_id = to_update.opportunity_id AND sv.tp_mod_concorrencia = to_update.tp_mod_concorrencia;
      GET DIAGNOSTICS v_sisu_vac_updated = ROW_COUNT;

      IF v_sisu_vac_updated < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
          AND NOT EXISTS (
            SELECT 1 FROM public.opportunities_sisu_vacancies sv WHERE sv.opportunity_id = o.id
          )
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'sisu'
            AND NOT EXISTS (
              SELECT 1 FROM public.opportunities_sisu_vacancies sv_inner WHERE sv_inner.opportunity_id = o_inner.id
            )
          LIMIT (p_limit - v_sisu_vac_updated)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_sisu_vac_updated + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'prouni_base' OR v_etl_type = 'prouni_clone' THEN
      -- Delete opportunities_prouni_vacancies in batches (opps deleted once vacancies drained).
      DELETE FROM public.opportunities_prouni_vacancies pv
      WHERE pv.ctid IN (
        SELECT pv_inner.ctid FROM public.opportunities_prouni_vacancies pv_inner
        JOIN public.opportunities o ON o.id = pv_inner.opportunity_id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni'
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_prouni_vac_deleted = ROW_COUNT;

      IF v_prouni_vac_deleted < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni'
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'prouni'
          LIMIT (p_limit - v_prouni_vac_deleted)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_prouni_vac_deleted + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
      RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
    ELSE
      RAISE EXCEPTION 'Unknown ETL type for rollback: %', v_etl_type;
    END IF;

    v_total_processed := COALESCE(v_vacancies_deleted, 0) + COALESCE(v_opps_deleted, 0)
      + COALESCE(v_prouni_vac_deleted, 0) + COALESCE(v_sisu_vac_updated, 0);

    UPDATE public.etl_run_logs
    SET records_processed = COALESCE(records_processed, 0) + v_total_processed
    WHERE id = v_new_log_id;

    IF NOT v_has_more THEN
      v_detail_msg := 'Rollback concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Tipo revertido: ' || v_etl_type || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

      UPDATE public.etl_run_logs
      SET status = 'success', errors = v_detail_msg, finished_at = now()
      WHERE id = v_new_log_id;
    END IF;

    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Rollback batch processed.',
      'processed', v_total_processed,
      'has_more', v_has_more,
      'log_id', v_new_log_id
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_new_log_id;

    RAISE EXCEPTION 'Rollback failed: %', SQLERRM;
  END;
END;
$$;


ALTER FUNCTION "public"."etl_rollback_log"("p_log_id" "uuid", "p_limit" integer, "p_active_rollback_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."etl_stop_log"("p_log_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_pid INTEGER;
  v_cancelled BOOLEAN := FALSE;
BEGIN
  -- 1. Read the backend that was last running this import.
  SELECT backend_pid INTO v_pid FROM public.etl_run_logs WHERE id = p_log_id;

  -- 2. Mark the log as cancelled (distinct from a real error).
  UPDATE public.etl_run_logs
  SET status = 'cancelled', errors = 'Cancelado pelo usuário', finished_at = now()
  WHERE id = p_log_id AND status = 'running';

  -- 3. If we know the pid, cancel it — but only if it is STILL running an
  --    etl_import statement, so we never cancel an unrelated pooled backend.
  IF v_pid IS NOT NULL AND v_pid <> pg_backend_pid() THEN
    IF EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE pid = v_pid AND state = 'active' AND query ILIKE '%etl_import_%'
    ) THEN
      PERFORM pg_cancel_backend(v_pid);
      v_cancelled := TRUE;
    END IF;
  END IF;

  -- 4. Fallback for legacy logs without a recorded pid: best-effort query match.
  IF NOT v_cancelled AND v_pid IS NULL THEN
    SELECT pid INTO v_pid
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query ILIKE '%etl_import_%'
      AND query ILIKE '%' || p_log_id::text || '%'
      AND pid <> pg_backend_pid()
    LIMIT 1;
    IF v_pid IS NOT NULL THEN
      PERFORM pg_cancel_backend(v_pid);
      v_cancelled := TRUE;
    END IF;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'pid_cancelled', CASE WHEN v_cancelled THEN v_pid ELSE NULL END);
END;
$$;


ALTER FUNCTION "public"."etl_stop_log"("p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."evaluate_partner_eligibility"("p_profile_id" "uuid", "p_partner_opportunity_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
    v_profile    public.user_profiles%ROWTYPE;
    v_income     numeric;
    v_form       RECORD;
    v_total      int := 0;
    v_met        int := 0;
    v_val_text   text;
    v_val_num    numeric;
    v_rule       jsonb;
    v_cond       jsonb;
    v_ok         boolean;
    v_details    jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_profile FROM public.user_profiles WHERE id = p_profile_id;

    SELECT per_capita_income INTO v_income
    FROM public.user_income WHERE user_id = p_profile_id
    ORDER BY updated_at DESC NULLS LAST LIMIT 1;

    FOR v_form IN
        SELECT field_name, mapping_source, criterion_rule
        FROM public.partner_forms
        WHERE partner_id = p_partner_opportunity_id AND is_criterion = true
    LOOP
        -- resolve valor via mapping_source
        v_val_text := CASE v_form.mapping_source
            WHEN 'user_profiles.age'             THEN v_profile.age::text
            WHEN 'user_profiles.education'        THEN v_profile.education
            WHEN 'user_profiles.education_year'   THEN v_profile.education_year
            WHEN 'user_profiles.state'            THEN v_profile.state
            WHEN 'user_income.per_capita_income'  THEN v_income::text
            ELSE NULL  -- campo sem mapeamento (só respondível no form) → ignora
        END;

        IF v_val_text IS NULL OR btrim(v_val_text) = '' OR v_val_text = 'N/A' THEN
            CONTINUE;  -- não avaliável → fora do total
        END IF;

        v_total  := v_total + 1;
        v_val_num := public._eligib_to_num(v_val_text);
        v_rule   := v_form.criterion_rule;

        IF v_rule IS NULL THEN
            v_ok := true;
        ELSIF v_rule ? 'and' THEN
            v_ok := true;
            FOR v_cond IN SELECT * FROM jsonb_array_elements(v_rule->'and') LOOP
                IF NOT public._eligib_eval_leaf(v_val_text, v_val_num, v_cond) THEN
                    v_ok := false; EXIT;
                END IF;
            END LOOP;
        ELSIF v_rule ? 'or' THEN
            v_ok := false;
            FOR v_cond IN SELECT * FROM jsonb_array_elements(v_rule->'or') LOOP
                IF public._eligib_eval_leaf(v_val_text, v_val_num, v_cond) THEN
                    v_ok := true; EXIT;
                END IF;
            END LOOP;
        ELSE
            v_ok := public._eligib_eval_leaf(v_val_text, v_val_num, v_rule);
        END IF;

        IF v_ok THEN v_met := v_met + 1; END IF;
        v_details := v_details || jsonb_build_object('field', v_form.field_name, 'met', v_ok);
    END LOOP;

    RETURN jsonb_build_object(
        'total', v_total,
        'met',   v_met,
        'score', CASE WHEN v_total = 0 THEN 100.0
                      ELSE round((v_met::numeric / v_total) * 100, 2) END,
        'details', v_details
    );
END;
$$;


ALTER FUNCTION "public"."evaluate_partner_eligibility"("p_profile_id" "uuid", "p_partner_opportunity_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."evaluate_partner_eligibility"("p_profile_id" "uuid", "p_partner_opportunity_id" "uuid") IS 'Score de elegibilidade (met/total*100) de um perfil para um partner_opportunity, via partner_forms+JsonLogic. total=0 → 100.';



CREATE OR REPLACE FUNCTION "public"."execute_readonly_query"("query_text" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  result jsonb;
  v_query text;
BEGIN
  -- Forçar modo read-only — qualquer INSERT/UPDATE/DELETE será rejeitado
  SET TRANSACTION READ ONLY;

  -- Normalizar: tirar espaços nas pontas e ponto-e-vírgula(s) final(is),
  -- que quebram o embrulho `FROM (<query>) t`.
  v_query := rtrim(btrim(query_text), ';');

  EXECUTE format('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', v_query)
    INTO result;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION "public"."execute_readonly_query"("query_text" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."execute_readonly_query"("query_text" "text") IS 'Executa query SQL read-only. Usada pelo MCP Server para buscas no catálogo educacional.';



CREATE OR REPLACE FUNCTION "public"."f_parse_ptbr_numeric"("p_val" "text") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    AS $$
DECLARE
  v  text := trim(coalesce(p_val, ''));
  rc int;  -- distance-from-end of last comma (0 = absent)
  rd int;  -- distance-from-end of last dot   (0 = absent)
BEGIN
  IF v = '' THEN RETURN NULL; END IF;

  -- keep only digits, separators and a leading sign
  v := regexp_replace(v, '[^0-9,.\-]', '', 'g');
  IF v = '' OR v = '-' THEN RETURN NULL; END IF;

  rc := position(',' in reverse(v));
  rd := position('.' in reverse(v));

  IF rc > 0 AND rd > 0 THEN
    IF rc < rd THEN
      -- comma is closer to the end -> comma is decimal (e.g. 1.234,56)
      v := replace(replace(v, '.', ''), ',', '.');
    ELSE
      -- dot is closer to the end -> dot is decimal (e.g. 1,234.56)
      v := replace(v, ',', '');
    END IF;
  ELSIF rc > 0 THEN
    -- only comma present -> decimal (e.g. 450,00)
    v := replace(v, ',', '.');
  ELSE
    -- only dot(s) or none. A single dot is decimal (450.00); several dots are
    -- thousands grouping (1.234.567) and get stripped.
    IF (length(v) - length(replace(v, '.', ''))) > 1 THEN
      v := replace(v, '.', '');
    END IF;
  END IF;

  RETURN v::numeric;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."f_parse_ptbr_numeric"("p_val" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."f_unaccent"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    AS $$
  SELECT translate(
    lower(p_text),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiioooooouuuucnaaaaaeeeeiiiioooooouuuucn'
  );
$$;


ALTER FUNCTION "public"."f_unaccent"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_applications_over_time"() RETURNS TABLE("date" "text", "count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        to_char(created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD') AS date,
        COUNT(*) AS count
    FROM public.student_applications
    GROUP BY to_char(created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD')
    ORDER BY date ASC;
END;
$$;


ALTER FUNCTION "public"."get_admin_applications_over_time"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_applications_over_time"("p_partner_id" "uuid" DEFAULT NULL::"uuid", "p_days_ago" integer DEFAULT 30) RETURNS TABLE("date" "text", "partner_id" "uuid", "partner_name" "text", "count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        to_char(sa.created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD') AS date,
        sa.partner_id,
        po.name AS partner_name,
        COUNT(*) AS count
    FROM public.student_applications sa
    LEFT JOIN public.partner_opportunities po ON po.id = sa.partner_id
    WHERE (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
      AND (p_days_ago IS NULL OR sa.created_at >= (now() - (p_days_ago || ' days')::interval))
    GROUP BY to_char(sa.created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD'), sa.partner_id, po.name
    ORDER BY date ASC;
END;
$$;


ALTER FUNCTION "public"."get_admin_applications_over_time"("p_partner_id" "uuid", "p_days_ago" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_course_opportunities"("p_course_id" "uuid", "p_year" integer DEFAULT NULL::integer, "p_opportunity_type" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_course_opportunities: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(filtered) ORDER BY filtered.year DESC, filtered.semester, filtered.opportunity_type, filtered.shift), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      o.id,
      o.shift,
      o.scholarship_type,
      o.concurrency_type,
      o.concurrency_tags,
      o.scholarship_tags,
      o.cutoff_score,
      o.year,
      o.semester,
      o.opportunity_type
    FROM public.opportunities o
    WHERE o.course_id = p_course_id
      AND (p_year IS NULL OR o.year = p_year)
      AND (p_opportunity_type IS NULL OR lower(o.opportunity_type) = lower(p_opportunity_type))
    ORDER BY o.year DESC, o.semester, o.opportunity_type, o.shift
    LIMIT 500
  ) filtered;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_course_opportunities"("p_course_id" "uuid", "p_year" integer, "p_opportunity_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_educational_campus_options"("p_institution_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_campus_options: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(options) ORDER BY options.name), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT cp.id, cp.name, cp.city, cp.state
    FROM public.campus cp
    WHERE cp.institution_id = p_institution_id
    ORDER BY cp.name
    LIMIT 300
  ) options;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_educational_campus_options"("p_institution_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_educational_courses"("p_page" integer DEFAULT 0, "p_page_size" integer DEFAULT 20, "p_search" "text" DEFAULT NULL::"text", "p_institution_id" "uuid" DEFAULT NULL::"uuid", "p_campus_id" "uuid" DEFAULT NULL::"uuid", "p_degree" "text" DEFAULT NULL::"text", "p_year" integer DEFAULT NULL::integer, "p_opportunity_type" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_courses: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  IF p_page < 0 OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'get_admin_educational_courses: paginação inválida' USING ERRCODE = '22023';
  END IF;

  WITH filtered AS (
    SELECT
      c.id,
      c.course_name,
      c.course_code,
      c.degree_type,
      cp.id AS campus_id,
      cp.name AS campus_name,
      i.id AS institution_id,
      i.name AS institution_name,
      cp.city,
      cp.state,
      count(DISTINCT o.id)::integer AS opportunity_count
    FROM public.courses c
    JOIN public.campus cp ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id
    JOIN public.opportunities o ON o.course_id = c.id
    WHERE
      (p_institution_id IS NULL OR i.id = p_institution_id)
      AND (p_campus_id IS NULL OR cp.id = p_campus_id)
      AND (p_degree IS NULL OR c.degree_type = p_degree)
      AND (p_year IS NULL OR o.year = p_year)
      AND (p_opportunity_type IS NULL OR lower(o.opportunity_type) = lower(p_opportunity_type))
      AND (
        p_search IS NULL
        OR public.unaccent(c.course_name) ILIKE '%' || public.unaccent(p_search) || '%'
        OR public.unaccent(i.name) ILIKE '%' || public.unaccent(p_search) || '%'
        OR public.unaccent(cp.name) ILIKE '%' || public.unaccent(p_search) || '%'
        OR c.course_code ILIKE '%' || p_search || '%'
      )
    GROUP BY c.id, c.course_name, c.course_code, c.degree_type,
      cp.id, cp.name, i.id, i.name, cp.city, cp.state
  ),
  paged AS (
    SELECT * FROM filtered
    ORDER BY course_name, institution_name, campus_name, id
    LIMIT p_page_size
    OFFSET p_page * p_page_size
  )
  SELECT jsonb_build_object(
    'data', coalesce((
      SELECT jsonb_agg(to_jsonb(paged) ORDER BY course_name, institution_name)
      FROM paged
    ), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_educational_courses"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_institution_id" "uuid", "p_campus_id" "uuid", "p_degree" "text", "p_year" integer, "p_opportunity_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_educational_filter_options"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_filter_options: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'institutions', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) ORDER BY i.name)
      FROM public.institutions i
    ), '[]'::jsonb),
    'degrees', coalesce((
      SELECT jsonb_agg(degree_type ORDER BY degree_type)
      FROM (SELECT DISTINCT c.degree_type FROM public.courses c WHERE c.degree_type IS NOT NULL) degrees
    ), '[]'::jsonb),
    'years', coalesce((
      SELECT jsonb_agg(year ORDER BY year DESC)
      FROM (SELECT DISTINCT o.year FROM public.opportunities o WHERE o.year IS NOT NULL) years
    ), '[]'::jsonb),
    'states', coalesce((
      SELECT jsonb_agg(state ORDER BY state)
      FROM (
        SELECT ie.state FROM public.institutions_info_emec ie WHERE ie.state IS NOT NULL
        UNION
        SELECT cp.state FROM public.campus cp WHERE cp.state IS NOT NULL
      ) states
    ), '[]'::jsonb)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_educational_filter_options"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_educational_institutions"("p_page" integer DEFAULT 0, "p_page_size" integer DEFAULT 20, "p_search" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_source" "text" DEFAULT 'all'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_educational_institutions: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  IF p_page < 0 OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'get_admin_educational_institutions: paginação inválida' USING ERRCODE = '22023';
  END IF;

  WITH campus_rollup AS (
    SELECT
      cp.institution_id,
      min(cp.state) FILTER (WHERE cp.state IS NOT NULL) AS campus_state,
      count(DISTINCT cp.id)::integer AS campus_count,
      count(DISTINCT c.id)::integer AS course_count
    FROM public.campus cp
    LEFT JOIN public.courses c ON c.campus_id = cp.id
    GROUP BY cp.institution_id
  ),
  filtered AS (
    SELECT
      i.id,
      i.name,
      i.external_code,
      i.is_partner,
      coalesce(ie.state, cr.campus_state) AS state,
      ie.igc,
      coalesce(cr.campus_count, 0) AS campus_count,
      coalesce(cr.course_count, 0) AS course_count,
      coalesce(ui.open_opportunities_count, 0)::integer AS open_opportunities_count
    FROM public.institutions i
    LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
    LEFT JOIN campus_rollup cr ON cr.institution_id = i.id
    LEFT JOIN public.v_unified_institutions ui ON ui.id = i.id
    WHERE
      (p_search IS NULL OR i.name ILIKE '%' || p_search || '%' OR i.external_code ILIKE '%' || p_search || '%')
      AND (
        p_state IS NULL
        OR ie.state = p_state
        OR EXISTS (
          SELECT 1 FROM public.campus state_campus
          WHERE state_campus.institution_id = i.id AND state_campus.state = p_state
        )
      )
      AND (
        p_source = 'all'
        OR (p_source = 'partner' AND i.is_partner)
        OR (p_source = 'mec' AND ie.institution_id IS NOT NULL)
      )
  ),
  paged AS (
    SELECT *
    FROM filtered
    ORDER BY name, id
    LIMIT p_page_size
    OFFSET p_page * p_page_size
  )
  SELECT jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(to_jsonb(paged) ORDER BY name) FROM paged), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_educational_institutions"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_state" "text", "p_source" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_funnel_users"() RETURNS TABLE("whatsapp" "text", "full_name" "text", "funnel_phase" "text", "step_order" integer, "furthest_passport_phase" "text", "active_partner_name" "text", "progress_percent" integer, "progress_filled" integer, "progress_total" integer, "is_dependent" boolean, "parent_full_name" "text", "external_redirect_clicks" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH latest_app AS (
        SELECT DISTINCT ON (sa.user_id)
            sa.user_id,
            po.name AS partner_name,
            sa.status,
            sa.partner_id,
            (SELECT count(*) FROM jsonb_object_keys(sa.answers)) AS filled_count
        FROM public.student_applications sa
        JOIN public.partner_opportunities po ON po.id = sa.partner_id
        ORDER BY sa.user_id, sa.updated_at DESC
    ),
    partner_totals AS (
        SELECT partner_id, count(*) AS total_count
        FROM public.partner_forms
        GROUP BY partner_id
    ),
    user_redirects AS (
        SELECT user_id, count(*) AS click_count
        FROM public.external_redirect_clicks
        GROUP BY user_id
    )
    SELECT
        CASE
            WHEN v.isdependent = true THEN parent_au.phone::text
            ELSE au.phone::text
        END AS whatsapp,
        v.full_name::text,
        CASE
            WHEN v.total_applications_submitted >= 2 THEN '6. 2ª Candidatura Concluída'
            WHEN v.total_applications_started >= 2 THEN '5. 2ª Candidatura Iniciada'
            WHEN v.total_applications_submitted >= 1 THEN '4. 1ª Candidatura Concluída'
            WHEN v.total_applications_started >= 1 THEN '3. 1ª Candidatura Iniciada'
            WHEN v.passport_started = true THEN '2. Passaporte Iniciado'
            ELSE '1. Total de Usuários'
        END AS funnel_phase,
        CASE
            WHEN v.total_applications_submitted >= 2 THEN 6
            WHEN v.total_applications_started >= 2 THEN 5
            WHEN v.total_applications_submitted >= 1 THEN 4
            WHEN v.total_applications_started >= 1 THEN 3
            WHEN v.passport_started = true THEN 2
            ELSE 1
        END AS step_order,
        v.furthest_passport_phase::text,
        laa.partner_name,
        CASE
            WHEN laa.status = 'SUBMITTED' THEN 100
            WHEN pt.total_count > 0 THEN LEAST(100, ROUND((laa.filled_count * 100.0) / pt.total_count))::integer
            ELSE NULL
        END AS progress_percent,
        laa.filled_count::integer AS progress_filled,
        pt.total_count::integer AS progress_total,
        v.isdependent AS is_dependent,
        parent_up.full_name::text AS parent_full_name,
        COALESCE(ur.click_count, 0)::integer AS external_redirect_clicks
    FROM public.vw_admin_user_funnel v
    LEFT JOIN auth.users au ON au.id = v.user_id
    LEFT JOIN latest_app laa ON laa.user_id = v.user_id
    LEFT JOIN partner_totals pt ON pt.partner_id = laa.partner_id
    LEFT JOIN public.user_profiles parent_up ON parent_up.id = v.parent_user_id
    LEFT JOIN auth.users parent_au ON parent_au.id = v.parent_user_id
    LEFT JOIN user_redirects ur ON ur.user_id = v.user_id
    ORDER BY step_order DESC, v.full_name ASC;
END;
$$;


ALTER FUNCTION "public"."get_admin_funnel_users"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_institution_campuses"("p_institution_id" "uuid", "p_page" integer DEFAULT 0, "p_page_size" integer DEFAULT 15, "p_search" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_admin_institution_campuses: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;

  IF p_page < 0 OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'get_admin_institution_campuses: paginação inválida' USING ERRCODE = '22023';
  END IF;

  WITH course_rollup AS (
    SELECT
      c.campus_id,
      count(DISTINCT c.id)::integer AS course_count,
      count(o.id)::integer AS opportunity_count
    FROM public.courses c
    LEFT JOIN public.opportunities o ON o.course_id = c.id
    GROUP BY c.campus_id
  ),
  filtered AS (
    SELECT
      cp.id,
      cp.name,
      cp.external_code,
      cp.city,
      cp.state,
      coalesce(cr.course_count, 0) AS course_count,
      coalesce(cr.opportunity_count, 0) AS opportunity_count
    FROM public.campus cp
    LEFT JOIN course_rollup cr ON cr.campus_id = cp.id
    WHERE cp.institution_id = p_institution_id
      AND (
        p_search IS NULL
        OR cp.name ILIKE '%' || p_search || '%'
        OR cp.city ILIKE '%' || p_search || '%'
      )
  ),
  paged AS (
    SELECT * FROM filtered
    ORDER BY name, id
    LIMIT p_page_size
    OFFSET p_page * p_page_size
  )
  SELECT jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(to_jsonb(paged) ORDER BY name) FROM paged), '[]'::jsonb),
    'total', (SELECT count(*) FROM filtered)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_institution_campuses"("p_institution_id" "uuid", "p_page" integer, "p_page_size" integer, "p_search" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_backoffice_users"() RETURNS TABLE("id" "uuid", "email" "text", "permissions" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        u.id,
        u.email::TEXT,
        ARRAY_AGG(up.permission ORDER BY up.permission) as permissions
    FROM 
        auth.users u
    JOIN 
        public.user_permissions up ON u.id = up.user_id
    GROUP BY 
        u.id, u.email;
END;
$$;


ALTER FUNCTION "public"."get_backoffice_users"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_channel_performance"("p_since" "date" DEFAULT NULL::"date", "p_until" "date" DEFAULT NULL::"date") RETURNS json
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_result JSON;
  v_from TIMESTAMPTZ := coalesce(p_since::timestamptz, '-infinity'::timestamptz);
  v_to   TIMESTAMPTZ := coalesce((p_until + 1)::timestamptz, 'infinity'::timestamptz);
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_channel_performance: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  WITH clicks AS (
    -- SUM(event_count) e não COUNT(*): linhas vindas de agregado legado
    -- representam N cliques numa linha só.
    SELECT e.channel_link_id, sum(e.event_count)::bigint AS clicks
    FROM public.engagement_events e
    WHERE e.channel_link_id IS NOT NULL
      AND e.occurred_at >= v_from AND e.occurred_at < v_to
    GROUP BY 1
  ),
  signups AS (
    -- FIRST touch: quem trouxe a pessoa. Creditar ao last touch faria o canal
    -- de reengajamento levar o mérito da aquisição.
    SELECT ua.first_touch_link_id AS link_id, count(*)::bigint AS signups
    FROM public.user_attribution ua
    WHERE ua.first_touch_link_id IS NOT NULL
      AND ua.first_touch_at >= v_from AND ua.first_touch_at < v_to
    GROUP BY 1
  ),
  matched AS (
    SELECT ua.first_touch_link_id AS link_id, count(DISTINCT ua.user_id)::bigint AS matched
    FROM public.user_attribution ua
    WHERE ua.first_touch_link_id IS NOT NULL
      AND ua.first_touch_at >= v_from AND ua.first_touch_at < v_to
      AND EXISTS (SELECT 1 FROM public.user_opportunity_matches m WHERE m.profile_id = ua.user_id)
    GROUP BY 1
  ),
  applied AS (
    -- status <> 'DRAFT': rascunho não é candidatura. `SUBMITTED` morreu em
    -- março e o que cresce hoje é `redirected`, então filtrar pelo negativo é
    -- o que sobrevive à mudança de vocabulário.
    SELECT ua.first_touch_link_id AS link_id, count(DISTINCT ua.user_id)::bigint AS applied
    FROM public.user_attribution ua
    WHERE ua.first_touch_link_id IS NOT NULL
      AND ua.first_touch_at >= v_from AND ua.first_touch_at < v_to
      AND EXISTS (
        SELECT 1 FROM public.student_applications sa
        WHERE sa.user_id = ua.user_id AND sa.status <> 'DRAFT'
      )
    GROUP BY 1
  ),
  per_link AS (
    SELECT
      l.id AS link_id,
      l.code,
      l.nickname,
      l.archived_at IS NOT NULL AS archived,
      c.id   AS campaign_id,
      c.name AS campaign_name,
      ch.id   AS channel_id,
      ch.name AS channel_name,
      ch.type AS medium,
      p.slug     AS platform_slug,
      p.name     AS platform_name,
      p.category AS platform_category,
      coalesce(cl.clicks, 0)   AS clicks,
      coalesce(s.signups, 0)   AS signups,
      coalesce(m.matched, 0)   AS matched,
      coalesce(a.applied, 0)   AS applied
    FROM public.channel_links l
    LEFT JOIN public.campaigns  c  ON c.id  = l.campaign_id
    JOIN      public.channels   ch ON ch.id = l.channel_id
    LEFT JOIN public.platforms  p  ON p.slug = l.platform_id
    LEFT JOIN clicks  cl ON cl.channel_link_id = l.id
    LEFT JOIN signups s  ON s.link_id  = l.id
    LEFT JOIN matched m  ON m.link_id  = l.id
    LEFT JOIN applied a  ON a.link_id  = l.id
  ),
  -- A taxa só existe onde há denominador. Sem clique, NULL — nunca 0, nunca
  -- infinito. É a regra que impede o cold start virar número mentiroso.
  scored AS (
    SELECT *,
      CASE WHEN clicks > 0 THEN round((signups::numeric / clicks) * 100, 1) END AS conversion_rate,
      clicks > 0 AS has_click_data
    FROM per_link
  )
  SELECT json_build_object(
    'links', (
      SELECT coalesce(json_agg(row_to_json(s) ORDER BY s.signups DESC, s.clicks DESC), '[]'::json)
      FROM scored s
    ),
    'by_campaign', (
      SELECT coalesce(json_agg(t ORDER BY t.signups DESC), '[]'::json) FROM (
        SELECT
          coalesce(campaign_name, 'Sem campanha') AS name,
          sum(clicks)  AS clicks,
          sum(signups) AS signups,
          sum(matched) AS matched,
          sum(applied) AS applied,
          count(*)     AS links,
          CASE WHEN sum(clicks) > 0
               THEN round((sum(signups)::numeric / sum(clicks)) * 100, 1) END AS conversion_rate
        FROM scored GROUP BY 1
      ) t
    ),
    'by_medium', (
      SELECT coalesce(json_agg(t ORDER BY t.signups DESC), '[]'::json) FROM (
        SELECT medium AS name, sum(clicks) AS clicks, sum(signups) AS signups,
               count(*) AS links,
               CASE WHEN sum(clicks) > 0
                    THEN round((sum(signups)::numeric / sum(clicks)) * 100, 1) END AS conversion_rate
        FROM scored GROUP BY 1
      ) t
    ),
    'by_platform', (
      SELECT coalesce(json_agg(t ORDER BY t.signups DESC), '[]'::json) FROM (
        SELECT coalesce(platform_name, 'Não informada') AS name,
               coalesce(platform_category, '—') AS category,
               sum(clicks) AS clicks, sum(signups) AS signups, count(*) AS links,
               CASE WHEN sum(clicks) > 0
                    THEN round((sum(signups)::numeric / sum(clicks)) * 100, 1) END AS conversion_rate
        FROM scored GROUP BY 1, 2
      ) t
    ),
    'totals', (
      SELECT json_build_object(
        'links',    count(*),
        'clicks',   coalesce(sum(clicks), 0),
        'signups',  coalesce(sum(signups), 0),
        'matched',  coalesce(sum(matched), 0),
        'applied',  coalesce(sum(applied), 0),
        -- A tela usa isto para decidir entre mostrar taxa ou explicar a
        -- ausência dela. Sem esta flag, "0 cliques" é indistinguível de
        -- "ninguém clicou", e são coisas muito diferentes.
        'has_any_click_data', coalesce(sum(clicks), 0) > 0,
        'first_click_at', (
          SELECT min(occurred_at) FROM public.engagement_events
          WHERE channel_link_id IS NOT NULL
        )
      ) FROM scored
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_channel_performance"("p_since" "date", "p_until" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_channel_performance"("p_since" "date", "p_until" "date") IS 'Desempenho por campanha/canal/plataforma para a tela de Canais (TP-7 7E, ADR-0028). Cadastros são creditados ao FIRST touch. Taxa de conversão é NULL quando não há clique no período — nunca 0 — porque cliques só passaram a ser gravados em 13/08/2026 e uma taxa sem denominador seria mentirosa.';



CREATE OR REPLACE FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) RETURNS TABLE("user_id" "uuid", "user_name" "text", "city" "text", "age" integer, "funnel_stage" "text", "last_activity" timestamp with time zone, "total_messages" bigint, "workflow" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH msg_stats AS (
        SELECT 
            cm.user_id,
            count(*) as total_msgs,
            max(cm.created_at) as last_act,
            -- Check for specific workflows
            bool_or(cm.workflow = 'match_workflow') as has_match_started,
            bool_or(cm.workflow IN ('sisu_workflow', 'prouni_workflow', 'fies_workflow')) as has_specific_flow,
            -- Simple dominant workflow approximation: most recent non-null workflow
            (array_agg(cm.workflow ORDER BY cm.created_at DESC) FILTER (WHERE cm.workflow IS NOT NULL))[1] as last_workflow
        FROM chat_messages cm
        WHERE cm.created_at >= p_date_from 
          AND cm.created_at <= p_date_to
          AND cm.user_id IS NOT NULL -- filter out system/null user messages if any
        GROUP BY cm.user_id
    ),
    fav_stats AS (
        SELECT 
            uf.user_id 
        FROM user_favorites uf
        GROUP BY uf.user_id
    )
    SELECT 
        ms.user_id,
        COALESCE(p.full_name, 'Usuário Anônimo') as user_name,
        p.city,
        p.age,
        -- Funnel Stage Logic (Priority Order matches TS code)
        CASE 
            WHEN ms.has_specific_flow THEN 'Fluxo Específico'
            WHEN fs.user_id IS NOT NULL THEN 'Salvaram Favoritos'
            WHEN (pref.workflow_data IS NOT NULL AND pref.workflow_data != '{}'::jsonb) THEN 'Match Realizado'
            WHEN ms.has_match_started THEN 'Match Iniciado'
            WHEN (pref.enem_score IS NOT NULL AND pref.enem_score > 0) THEN 'Preferências Definidas'
            WHEN p.onboarding_completed THEN 'Onboarding Completo'
            ELSE 'Cadastrados'
        END as funnel_stage,
        ms.last_act as last_activity,
        ms.total_msgs as total_messages,
        ms.last_workflow as workflow
    FROM msg_stats ms
    LEFT JOIN user_profiles p ON ms.user_id = p.id
    LEFT JOIN user_preferences pref ON ms.user_id = pref.user_id
    LEFT JOIN fav_stats fs ON ms.user_id = fs.user_id
    ORDER BY ms.last_act DESC;
END;
$$;


ALTER FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_command_center_demographics"() RETURNS json
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  v_result JSON;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_command_center_demographics: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    -- DISTINCT ON espelha a semântica de get_students_paginated: user_income e
    -- user_preferences podem ter mais de uma linha por usuário, e sem isso as
    -- contagens inflam silenciosamente.
    SELECT DISTINCT ON (p.id)
      p.id,
      nullif(trim(coalesce(p.education, '')), '')   AS education,
      nullif(trim(coalesce(p.race, '')), '')        AS race,
      nullif(trim(coalesce(p.school_type, '')), '') AS school_type,
      COALESCE(inc.per_capita_income, pref.family_income_per_capita) AS income
    FROM public.user_profiles p
    LEFT JOIN public.user_income inc ON inc.user_id = p.id
    LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
    ORDER BY p.id
  ),
  matched AS (
    SELECT DISTINCT profile_id FROM public.user_opportunity_matches
  ),
  health AS (
    SELECT
      count(*) FILTER (WHERE m.profile_id IS NOT NULL) AS with_match,
      count(*) FILTER (WHERE m.profile_id IS NULL)     AS without_match,
      count(*)                                          AS total
    FROM base b
    LEFT JOIN matched m ON m.profile_id = b.id
  ),
  -- Cada dimensão categórica vira (label, count). "Não respondeu" é bucket
  -- explícito e vai por último: campo em branco é informação, não ausência de
  -- linha, e some do gráfico se for tratado como NULL.
  dim_education AS (
    SELECT coalesce(education, 'Não respondeu') AS label, count(*)::bigint AS value,
           (education IS NULL) AS is_unanswered
    FROM base GROUP BY 1, 3
  ),
  dim_race AS (
    SELECT coalesce(race, 'Não respondeu') AS label, count(*)::bigint AS value,
           (race IS NULL) AS is_unanswered
    FROM base GROUP BY 1, 3
  ),
  dim_school AS (
    SELECT coalesce(school_type, 'Não respondeu') AS label, count(*)::bigint AS value,
           (school_type IS NULL) AS is_unanswered
    FROM base GROUP BY 1, 3
  ),
  -- Renda per capita está em BRL (o front formata com R$ e 2 casas — ver
  -- StudentExportButton.tsx e StudentDetailsModal.tsx). Faixas fixas em reais.
  dim_income AS (
    SELECT
      CASE
        WHEN income IS NULL       THEN 'Não respondeu'
        WHEN income <= 500        THEN 'Até R$ 500'
        WHEN income <= 1000       THEN 'R$ 500 a R$ 1.000'
        WHEN income <= 1500       THEN 'R$ 1.000 a R$ 1.500'
        WHEN income <= 3000       THEN 'R$ 1.500 a R$ 3.000'
        ELSE                           'Acima de R$ 3.000'
      END AS label,
      CASE
        WHEN income IS NULL THEN 99
        WHEN income <= 500  THEN 1
        WHEN income <= 1000 THEN 2
        WHEN income <= 1500 THEN 3
        WHEN income <= 3000 THEN 4
        ELSE 5
      END AS bucket_order,
      count(*)::bigint AS value
    FROM base GROUP BY 1, 2
  )
  SELECT json_build_object(
    'match_health', (
      SELECT json_build_object(
        'with_match', with_match,
        'without_match', without_match,
        'total', total
      ) FROM health
    ),
    'education', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY is_unanswered, value DESC, label), '[]'::json) FROM dim_education
    ),
    'income', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY bucket_order), '[]'::json) FROM dim_income
    ),
    'race', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY is_unanswered, value DESC, label), '[]'::json) FROM dim_race
    ),
    'school_type', (
      SELECT coalesce(json_agg(json_build_object('label', label, 'value', value)
             ORDER BY is_unanswered, value DESC, label), '[]'::json) FROM dim_school
    )
  ) INTO v_result;

  RETURN v_result;
END;
$_$;


ALTER FUNCTION "public"."get_command_center_demographics"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_command_center_demographics"() IS 'Saúde do match (pizza) + 4 distribuições demográficas do Command Center, num único round-trip. Devolve apenas contagens agregadas — nunca linhas identificáveis — e exige is_backoffice_admin(). TP-1 1B / card 7731cb55.';



CREATE OR REPLACE FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text" DEFAULT NULL::"text", "category" "text" DEFAULT NULL::"text", "sort_by" "text" DEFAULT NULL::"text", "user_city" "text" DEFAULT NULL::"text", "user_state" "text" DEFAULT NULL::"text", "user_lat" double precision DEFAULT NULL::double precision, "user_long" double precision DEFAULT NULL::double precision) RETURNS TABLE("id" "uuid", "course_name" "text", "institution_name" "text", "city" "text", "state" "text", "vacancies" "jsonb", "opportunities" json, "distance_km" double precision)
    LANGUAGE "sql"
    AS $$
  WITH filtered_courses AS (
    SELECT 
      mv.course_id as id,
      mv.course_name,
      mv.institution_name,
      mv.city,
      mv.state,
      mv.vacancies_json as vacancies,
      mv.opportunities_json as opportunities,
      mv.max_cutoff,
      mv.min_cutoff,
      mv.igc_value,
      -- Check if we can calculate distance
      CASE 
        WHEN user_lat IS NOT NULL AND user_long IS NOT NULL AND mv.latitude IS NOT NULL AND mv.longitude IS NOT NULL THEN
            (point(mv.longitude, mv.latitude) <@> point(user_long, user_lat)) * 1.60934
        ELSE 
            NULL 
      END as distance_km
    FROM mv_course_catalog mv
    WHERE
      -- 1. Search Logic using vector
      (search_query IS NULL OR search_query = '' OR mv.search_vector @@ to_tsquery('portuguese', regexp_replace(trim(unaccent(search_query)), '\s+', ' & ', 'g') || ':*'))
      AND
      -- 2. Filtering Logic using pre-calculated booleans
      (category IS NULL OR
        (category = 'SISU' AND mv.has_sisu = true)
        OR
        (category = 'Prouni' AND mv.has_prouni = true)
        OR
        (category = 'EAD' AND mv.has_ead = true)
        OR
        (category = 'Ações afirmativas' AND mv.has_affirmative_action = true)
        OR
        (category = 'Seleção Nubo' AND mv.has_nubo_pick = true)
      )
  ),
  sorted_courses AS (
    SELECT * FROM filtered_courses
    ORDER BY
      CASE 
        WHEN sort_by = 'proximas' AND user_lat IS NOT NULL THEN
           distance_km
        ELSE NULL
      END ASC NULLS LAST,
      
      -- Fallback for 'proximas' when distance is NULL (missing coords) or user_lat is NULL
      CASE 
        WHEN sort_by = 'proximas' THEN
           CASE 
             WHEN user_city IS NOT NULL AND f_unaccent(city) ILIKE f_unaccent(user_city) THEN 0 
             ELSE 1 
           END
        ELSE 0
      END ASC,
      
      CASE 
        WHEN sort_by = 'proximas' THEN
           CASE 
             WHEN user_state IS NOT NULL AND state ILIKE user_state THEN 0 
             ELSE 1 
           END
        ELSE 0
      END ASC,

      CASE 
        WHEN sort_by = 'melhores' THEN igc_value
        ELSE 0 
      END DESC,
      CASE 
        WHEN sort_by = 'maior_nota' THEN max_cutoff
        ELSE NULL
      END DESC NULLS LAST,
      CASE 
        WHEN sort_by = 'menor_nota' THEN min_cutoff
        ELSE NULL
      END ASC NULLS LAST,
      -- Default / Tie-breaker
      id ASC
    LIMIT page_size
    OFFSET page_number * page_size
  )
  SELECT
    sc.id,
    sc.course_name,
    sc.institution_name,
    sc.city,
    sc.state,
    sc.vacancies,
    sc.opportunities,
    sc.distance_km
  FROM sorted_courses sc;
$$;


ALTER FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_eligible_count_by_institution"("p_institution_id" "uuid") RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
        SELECT COALESCE(COUNT(DISTINCT sa.user_id), 0)
        FROM public.student_applications sa
        JOIN public.partner_opportunities po ON sa.partner_id = po.id
        WHERE po.institution_id = p_institution_id
          AND jsonb_typeof(sa.eligibility_results) = 'array'
          AND jsonb_array_length(sa.eligibility_results) > 0
          AND NOT EXISTS (
             SELECT 1 FROM jsonb_array_elements(sa.eligibility_results) AS elem
             WHERE (elem->>'met')::boolean = false
          );
      $$;


ALTER FUNCTION "public"."get_eligible_count_by_institution"("p_institution_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_eligible_count_for_partner"("p_partner_id" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
      $$;


ALTER FUNCTION "public"."get_eligible_count_for_partner"("p_partner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_influencer_affiliates"("influencer_code" "text") RETURNS TABLE("id" "uuid", "full_name" "text", "phone" "text", "age" integer, "city" "text", "created_at" timestamp with time zone, "last_sign_in_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    RETURN QUERY SELECT up.id, up.full_name, u.phone, up.age, up.city, u.created_at, u.last_sign_in_at
    FROM public.user_profiles up JOIN auth.users u ON up.id = u.id WHERE up.referral_source = influencer_code ORDER BY u.created_at DESC;
END; $$;


ALTER FUNCTION "public"."get_influencer_affiliates"("influencer_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_influencer_dashboard_stats"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    total_affiliates BIGINT;
    best_influencer_name TEXT;
    best_influencer_count BIGINT;
    influencer_count BIGINT;
    result JSON;
BEGIN
    -- Total affiliates
    SELECT COUNT(*) INTO total_affiliates 
    FROM public.user_profiles 
    WHERE referral_source IS NOT NULL;

    -- Best influencer
    SELECT 
        i.name, COUNT(up.id) as cnt INTO best_influencer_name, best_influencer_count
    FROM 
        public.influencers i
    JOIN 
        public.user_profiles up ON i.code = up.referral_source
    GROUP BY 
        i.name
    ORDER BY 
        cnt DESC
    LIMIT 1;

    -- Total active influencers
    SELECT COUNT(*) INTO influencer_count 
    FROM public.influencers 
    WHERE active = TRUE;

    result := json_build_object(
        'total_affiliates', total_affiliates,
        'best_influencer', COALESCE(best_influencer_name, 'Nenhum'),
        'avg_affiliates', CASE WHEN influencer_count > 0 THEN (total_affiliates::FLOAT / influencer_count) ELSE 0 END
    );

    RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_influencer_dashboard_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_influencer_stats"("p_sort_by" "text" DEFAULT 'name'::"text", "p_sort_order" "text" DEFAULT 'asc'::"text") RETURNS TABLE("id" "uuid", "name" "text", "code" "text", "active" boolean, "affiliate_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_order_clause TEXT;
BEGIN
    v_order_clause := CASE p_sort_by
        WHEN 'name' THEN 'i.name'
        WHEN 'code' THEN 'i.code'
        WHEN 'affiliate_count' THEN 'COUNT(up.id)'
        ELSE 'i.name'
    END;

    RETURN QUERY EXECUTE format('
        SELECT i.id, i.name, i.code, i.active, COUNT(up.id) as affiliate_count
        FROM public.influencers i LEFT JOIN public.user_profiles up ON i.code = up.referral_source
        WHERE i.active = TRUE GROUP BY i.id, i.name, i.code, i.active
        ORDER BY %s %s',
        v_order_clause,
        CASE WHEN lower(p_sort_order) = 'desc' THEN 'DESC' ELSE 'ASC' END
    );
END; $$;


ALTER FUNCTION "public"."get_influencer_stats"("p_sort_by" "text", "p_sort_order" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_knowledge_documents"("p_category_id" "uuid" DEFAULT NULL::"uuid", "p_partner_id" "uuid" DEFAULT NULL::"uuid", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_results JSONB;
BEGIN
    SELECT jsonb_agg(row_data ORDER BY row_data->>'updated_at' DESC) INTO v_results
    FROM (
        SELECT jsonb_build_object(
            'id', kd.id,
            'title', kd.title,
            'description', kd.description,
            'category_id', kd.category_id,
            'category_name', kc.name,
            'category_label', kc.label,
            'partner_id', kd.partner_id,
            'partner_name', p.name,
            'storage_path', kd.storage_path,
            'is_active', kd.is_active,
            'current_version', kd.current_version,
            'created_by', kd.created_by,
            'created_at', kd.created_at,
            'updated_at', kd.updated_at,
            'keywords', COALESCE((
                SELECT jsonb_agg(kk.keyword)
                FROM public.knowledge_keywords kk
                WHERE kk.document_id = kd.id
            ), '[]'::jsonb),
            'partner_opportunities', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', po.id, 'name', po.name))
                FROM public.knowledge_document_opportunities kdo
                JOIN public.partner_opportunities po ON po.id = kdo.partner_opportunity_id
                WHERE kdo.document_id = kd.id
            ), '[]'::jsonb)
        ) AS row_data
        FROM public.knowledge_documents kd
        LEFT JOIN public.knowledge_categories kc ON kd.category_id = kc.id
        LEFT JOIN public.partner_opportunities p ON kd.partner_id = p.id
        WHERE (p_category_id IS NULL OR kd.category_id = p_category_id)
          AND (
            p_partner_id IS NULL
            OR kd.partner_id = p_partner_id
            OR EXISTS (
                SELECT 1 FROM public.knowledge_document_opportunities kdo
                WHERE kdo.document_id = kd.id AND kdo.partner_opportunity_id = p_partner_id
            )
          )
          AND (p_is_active IS NULL OR kd.is_active = p_is_active)
    ) sub;

    RETURN COALESCE(v_results, '[]'::jsonb);
END;
$$;


ALTER FUNCTION "public"."get_knowledge_documents"("p_category_id" "uuid", "p_partner_id" "uuid", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_partner_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT partner_id
  FROM public.partners_users
  WHERE user_id = auth.uid()
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_my_partner_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_opportunities_for_user"("p_profile_id" "uuid", "p_page" integer DEFAULT 0, "p_limit" integer DEFAULT 20) RETURNS TABLE("unified_id" "text", "title" "text", "provider_name" "text", "type" "text", "category" "text", "is_partner" boolean, "location" "text", "badges" "jsonb", "created_at" timestamp with time zone, "external_redirect_url" "text", "external_redirect_enabled" boolean, "status" "text", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "match_score" numeric, "match_details" "jsonb", "min_cutoff_score_current" numeric, "min_cutoff_score_prev" numeric, "max_cutoff_score_current" numeric, "max_cutoff_score_prev" numeric, "nu_media_minima_enem_current" numeric, "nu_media_minima_enem_prev" numeric, "institution_cover_url" "text", "opportunity_type" "text", "vagas_ociosas_current" boolean, "vagas_ociosas_prev" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        vo.unified_id, vo.title, vo.provider_name, vo.type, vo.category, vo.is_partner,
        vo.location, vo.badges, vo.created_at, vo.external_redirect_url,
        vo.external_redirect_enabled, vo.status, vo.starts_at, vo.ends_at,
        uom.match_score, uom.match_details,
        vo.min_cutoff_score_current, vo.min_cutoff_score_prev,
        vo.max_cutoff_score_current, vo.max_cutoff_score_prev,
        vo.nu_media_minima_enem_current, vo.nu_media_minima_enem_prev,
        vo.institution_cover_url, vo.opportunity_type,
        vo.vagas_ociosas_current, vo.vagas_ociosas_prev
    FROM public.v_unified_opportunities vo
    JOIN public.user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
    WHERE uom.profile_id = p_profile_id
      AND uom.match_score > 0
    ORDER BY
      (vo.status = 'opened') DESC,   -- Abertas primeiro
      vo.is_partner DESC,             -- Parceiros como desempate
      uom.match_score DESC NULLS LAST -- Match score final
    LIMIT p_limit OFFSET (p_page * p_limit);
END;
$$;


ALTER FUNCTION "public"."get_opportunities_for_user"("p_profile_id" "uuid", "p_page" integer, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_own_profile"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id UUID;
  v_profile RECORD;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_profile FROM public.user_profiles WHERE id = v_user_id;

  IF v_profile IS NULL THEN
    -- Auto-create profile on first access with INTRO phase
    INSERT INTO public.user_profiles (id, passport_phase)
    VALUES (v_user_id, 'INTRO')
    ON CONFLICT (id) DO NOTHING
    RETURNING * INTO v_profile;
    
    -- If conflict happened (e.g. race condition) and RETURNING didn't work, select again
    IF v_profile IS NULL THEN
       SELECT * INTO v_profile FROM public.user_profiles WHERE id = v_user_id;
    END IF;
  END IF;

  -- One final check, theoretically shouldn't hit this unless insert failed without conflict
  IF v_profile IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN to_jsonb(v_profile);
END;
$$;


ALTER FUNCTION "public"."get_own_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_applications_by_institution"("p_institution_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "user_id" "uuid", "partner_id" "uuid", "partner_name" "text", "institution_id" "uuid", "institution_name" "text", "full_name" "text", "phone" "text", "status" "text", "answers" "jsonb", "eligibility_results" "jsonb", "created_at" timestamp with time zone, "phase_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    sa.id,
    sa.user_id,
    sa.partner_id,
    po.name AS partner_name,
    po.institution_id,
    inst.name AS institution_name,
    up.full_name,
    u.phone,
    sa.status,
    sa.answers,
    sa.eligibility_results,
    sa.created_at,
    sa.phase_id
  FROM
    public.student_applications sa
  LEFT JOIN
    public.partner_opportunities po ON sa.partner_id = po.id
  LEFT JOIN
    public.institutions inst ON po.institution_id = inst.id
  LEFT JOIN
    public.user_profiles up ON sa.user_id = up.id
  LEFT JOIN
    auth.users u ON sa.user_id = u.id
  WHERE
    (p_institution_id IS NULL OR po.institution_id = p_institution_id)
  ORDER BY
    sa.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_partner_applications_by_institution"("p_institution_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_redirect_users"("p_partner_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("user_id" "uuid", "full_name" "text", "whatsapp" "text", "redirect_url" "text", "created_at" timestamp with time zone, "city" "text", "state" "text", "education" "text", "age" integer, "neighborhood" "text", "street" "text", "street_number" "text", "complement" "text", "education_year" "text", "zip_code" "text", "country" "text", "course_interest" "text"[], "preferred_shifts" "text"[], "university_preference" "text", "program_preference" "text", "per_capita_income" numeric, "quota_types" "text"[], "partner_id" "uuid", "partner_name" "text")
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
    SELECT
        up.id AS user_id,
        up.full_name::text,
        au.phone::text AS whatsapp,
        erc.redirect_url,
        erc.created_at,
        up.city,
        up.state,
        up.education,
        up.age,
        up.neighborhood,
        up.street,
        up.street_number,
        up.complement,
        up.education_year,
        up.zip_code,
        up.country,
        upr.course_interest,
        upr.preferred_shifts,
        upr.university_preference,
        upr.program_preference,
        ui.per_capita_income,
        upr.quota_types,
        p.id AS partner_id,
        p.name AS partner_name
    FROM public.external_redirect_clicks erc
    JOIN public.user_profiles up ON up.id = erc.user_id
    JOIN public.partners p ON p.id = erc.partner_id
    LEFT JOIN auth.users au ON au.id = erc.user_id
    LEFT JOIN public.user_preferences upr ON upr.user_id = erc.user_id
    LEFT JOIN public.user_income ui ON ui.user_id = erc.user_id
    WHERE (p_partner_id IS NULL OR erc.partner_id = p_partner_id)
    ORDER BY erc.created_at DESC;
$$;


ALTER FUNCTION "public"."get_partner_redirect_users"("p_partner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_users"("p_partner_id" "text") RETURNS TABLE("id" "uuid", "user_id" "uuid", "email" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        pu.id,
        pu.user_id,
        u.email::TEXT,
        pu.created_at
    FROM 
        public.partners_users pu
    JOIN 
        auth.users u ON pu.user_id = u.id
    WHERE 
        pu.partner_id = p_partner_id::UUID
    ORDER BY 
        pu.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_partner_users"("p_partner_id" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."partners" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "location" "text",
    "type" "text",
    "income" "text",
    "dates" "jsonb",
    "link" "text",
    "coverimage" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "applications_open" boolean DEFAULT true,
    "external_redirect_config" "jsonb"
);


ALTER TABLE "public"."partners" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partners"("p_sort_by" "text" DEFAULT 'name'::"text", "p_sort_order" "text" DEFAULT 'asc'::"text") RETURNS SETOF "public"."partners"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY EXECUTE format('
    SELECT * 
    FROM public.partners
    ORDER BY %I %s',
    CASE 
      WHEN p_sort_by IN ('name', 'location', 'type') THEN p_sort_by 
      ELSE 'name' 
    END,
    CASE WHEN lower(p_sort_order) = 'desc' THEN 'DESC' ELSE 'ASC' END
  );
END;
$$;


ALTER FUNCTION "public"."get_partners"("p_sort_by" "text", "p_sort_order" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_passport_phase_weight"("phase" "text") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN CASE phase
        WHEN 'INTRO' THEN 1
        WHEN 'ONBOARDING' THEN 2
        WHEN 'ASK_DEPENDENT' THEN 3
        WHEN 'DEPENDENT_ONBOARDING' THEN 4
        WHEN 'PROGRAM_MATCH' THEN 5
        WHEN 'EVALUATE' THEN 6
        WHEN 'CONCLUDED' THEN 7
        ELSE 0
    END;
END;
$$;


ALTER FUNCTION "public"."get_passport_phase_weight"("phase" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text" DEFAULT NULL::"text", "p_filter_city" "text" DEFAULT NULL::"text", "p_filter_education" "text" DEFAULT NULL::"text", "p_filter_is_nubo_student" boolean DEFAULT NULL::boolean, "p_filter_income_min" numeric DEFAULT NULL::numeric, "p_filter_income_max" numeric DEFAULT NULL::numeric, "p_filter_quota_types" "text"[] DEFAULT NULL::"text"[]) RETURNS json
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_offset int;
  v_total_count bigint;
  v_data json;
BEGIN
  v_offset := p_page * p_page_size;

  -- 1. Calculate Total Count
  SELECT count(DISTINCT s.id)
  INTO v_total_count
  FROM public.sean_ellis_score s
  LEFT JOIN public.user_profiles p ON s.user_id = p.id
  LEFT JOIN public.user_preferences pref ON s.user_id = pref.user_id
  WHERE
    (p_filter_name IS NULL OR s.full_name ILIKE '%' || p_filter_name || '%' OR p.full_name ILIKE '%' || p_filter_name || '%')
    AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
    AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
    AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
    -- Preference Filters
    AND (p_filter_income_min IS NULL OR pref.family_income_per_capita >= p_filter_income_min)
    AND (p_filter_income_max IS NULL OR pref.family_income_per_capita <= p_filter_income_max)
    AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types);

  -- 2. Fetch Data
  SELECT coalesce(json_agg(t.*), '[]'::json)
  INTO v_data
  FROM (
      SELECT s.*
      FROM public.sean_ellis_score s
      LEFT JOIN public.user_profiles p ON s.user_id = p.id
      LEFT JOIN public.user_preferences pref ON s.user_id = pref.user_id
      WHERE
        (p_filter_name IS NULL OR s.full_name ILIKE '%' || p_filter_name || '%' OR p.full_name ILIKE '%' || p_filter_name || '%')
        AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
        AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
        AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
        -- Preference Filters
        AND (p_filter_income_min IS NULL OR pref.family_income_per_capita >= p_filter_income_min)
        AND (p_filter_income_max IS NULL OR pref.family_income_per_capita <= p_filter_income_max)
        AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types)
      ORDER BY s.submitted_at DESC
      LIMIT p_page_size
      OFFSET v_offset
  ) t;

  -- 3. Return combined JSON
  RETURN json_build_object(
      'data', v_data,
      'count', v_total_count
  );
END;
$$;


ALTER FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text" DEFAULT NULL::"text", "p_filter_city" "text" DEFAULT NULL::"text", "p_filter_education" "text" DEFAULT NULL::"text", "p_filter_is_nubo_student" boolean DEFAULT NULL::boolean, "p_filter_income_min" numeric DEFAULT NULL::numeric, "p_filter_income_max" numeric DEFAULT NULL::numeric, "p_filter_quota_types" "text"[] DEFAULT NULL::"text"[], "p_sort_by" "text" DEFAULT 'submitted_at'::"text", "p_sort_order" "text" DEFAULT 'desc'::"text") RETURNS json
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
  v_offset int;
  v_total_count bigint;
  v_data json;
  v_order_clause text;
BEGIN
  v_offset := p_page * p_page_size;

  -- Map sort_by to actual columns
  v_order_clause := CASE p_sort_by
    WHEN 'full_name' THEN 's.full_name'
    WHEN 'identified' THEN 's.user_id'
    WHEN 'disappointment_level' THEN 's.disappointment_level'
    WHEN 'sisu_subscribed' THEN 's.sisu_subscribed'
    WHEN 'prouni_subscribed' THEN 's.prouni_subscribed'
    ELSE 's.submitted_at'
  END;

  -- 1. Calculate Total Count
  SELECT count(DISTINCT s.id)
  INTO v_total_count
  FROM public.sean_ellis_score s
  LEFT JOIN public.user_profiles p ON s.user_id = p.id
  LEFT JOIN public.user_preferences pref ON s.user_id = pref.user_id
  WHERE
    (p_filter_name IS NULL OR s.full_name ILIKE '%' || p_filter_name || '%' OR p.full_name ILIKE '%' || p_filter_name || '%')
    AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
    AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
    AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
    -- Preference Filters
    AND (p_filter_income_min IS NULL OR pref.family_income_per_capita >= p_filter_income_min)
    AND (p_filter_income_max IS NULL OR pref.family_income_per_capita <= p_filter_income_max)
    AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types);

  -- 2. Fetch Data with dynamic sort
  EXECUTE format('
    SELECT coalesce(json_agg(t.*), ''[]''::json)
    FROM (
        SELECT s.*
        FROM public.sean_ellis_score s
        LEFT JOIN public.user_profiles p ON s.user_id = p.id
        LEFT JOIN public.user_preferences pref ON s.user_id = pref.user_id
        WHERE
          ($1 IS NULL OR s.full_name ILIKE ''%%'' || $1 || ''%%'' OR p.full_name ILIKE ''%%'' || $1 || ''%%'')
          AND ($2 IS NULL OR p.city ILIKE ''%%'' || $2 || ''%%'')
          AND ($3 IS NULL OR p.education ILIKE ''%%'' || $3 || ''%%'')
          AND ($4 IS NULL OR p.is_nubo_student = $4)
          AND ($5 IS NULL OR pref.family_income_per_capita >= $5)
          AND ($6 IS NULL OR pref.family_income_per_capita <= $6)
          AND ($7 IS NULL OR pref.quota_types && $7)
        ORDER BY %s %s
        LIMIT $8
        OFFSET $9
    ) t',
    v_order_clause,
    CASE WHEN lower(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END
  ) 
  USING 
    p_filter_name, 
    p_filter_city, 
    p_filter_education, 
    p_filter_is_nubo_student, 
    p_filter_income_min, 
    p_filter_income_max, 
    p_filter_quota_types,
    p_page_size,
    v_offset
  INTO v_data;

  -- 3. Return combined JSON
  RETURN json_build_object(
      'data', v_data,
      'count', v_total_count
  );
END;
$_$;


ALTER FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sean_ellis_stats"("p_filter_name" "text" DEFAULT NULL::"text", "p_filter_city" "text" DEFAULT NULL::"text", "p_filter_education" "text" DEFAULT NULL::"text", "p_filter_is_nubo_student" boolean DEFAULT NULL::boolean, "p_filter_income_min" numeric DEFAULT NULL::numeric, "p_filter_income_max" numeric DEFAULT NULL::numeric, "p_filter_quota_types" "text"[] DEFAULT NULL::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
    total_respondents INTEGER;
    total_identified_users INTEGER;
    disappointment_distribution JSONB;
BEGIN
    -- Simplification: count totals first
    SELECT 
        COUNT(s.id),
        COUNT(s.user_id)
    INTO 
        total_respondents,
        total_identified_users
    FROM public.sean_ellis_score s
    LEFT JOIN public.user_profiles p ON s.user_id = p.id
    LEFT JOIN public.user_preferences pref ON s.user_id = pref.user_id
    WHERE
        (p_filter_name IS NULL OR s.full_name ILIKE '%' || p_filter_name || '%' OR p.full_name ILIKE '%' || p_filter_name || '%')
        AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
        AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
        AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
        AND (p_filter_income_min IS NULL OR pref.family_income_per_capita >= p_filter_income_min)
        AND (p_filter_income_max IS NULL OR pref.family_income_per_capita <= p_filter_income_max)
        AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types);

    -- Calculate distribution separately to avoid complex grouping with filters
    SELECT jsonb_object_agg(t.disappointment_level, t.count)
    INTO disappointment_distribution
    FROM (
        SELECT s.disappointment_level, COUNT(*) as count
        FROM public.sean_ellis_score s
        LEFT JOIN public.user_profiles p ON s.user_id = p.id
        LEFT JOIN public.user_preferences pref ON s.user_id = pref.user_id
        WHERE
            (p_filter_name IS NULL OR s.full_name ILIKE '%' || p_filter_name || '%' OR p.full_name ILIKE '%' || p_filter_name || '%')
            AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
            AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
            AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
            AND (p_filter_income_min IS NULL OR pref.family_income_per_capita >= p_filter_income_min)
            AND (p_filter_income_max IS NULL OR pref.family_income_per_capita <= p_filter_income_max)
            AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types)
        GROUP BY s.disappointment_level
    ) t;

    RETURN jsonb_build_object(
        'total_respondents', total_respondents,
        'total_identified_users', total_identified_users,
        'disappointment_distribution', COALESCE(disappointment_distribution, '{}'::jsonb)
    );
END;
$$;


ALTER FUNCTION "public"."get_sean_ellis_stats"("p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "user_id" "uuid", "partner_id" "uuid", "partner_name" "text", "institution_id" "uuid", "institution_name" "text", "full_name" "text", "phone" "text", "status" "text", "answers" "jsonb", "created_at" timestamp with time zone, "eligibility_results" "jsonb", "phase_id" "uuid", "race" "text", "family_income_per_capita" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        sa.id,
        sa.user_id,
        sa.partner_id,
        po.name AS partner_name,
        po.institution_id,
        inst.name AS institution_name,
        up.full_name,
        u.phone,
        sa.status,
        sa.answers,
        sa.created_at,
        sa.eligibility_results,
        sa.phase_id,
        up.race,
        ui.per_capita_income AS family_income_per_capita
    FROM
        public.student_applications sa
    LEFT JOIN
        public.user_profiles up ON sa.user_id = up.id
    LEFT JOIN
        auth.users u ON sa.user_id = u.id
    LEFT JOIN
        public.partner_opportunities po ON sa.partner_id = po.id
    LEFT JOIN
        public.institutions inst ON po.institution_id = inst.id
    LEFT JOIN
        public.user_income ui ON sa.user_id = ui.user_id
    WHERE
        (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
    ORDER BY
        sa.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_clicks_admin"("p_user_id" "uuid", "p_page" integer DEFAULT 0, "p_page_size" integer DEFAULT 20) RETURNS json
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_total BIGINT;
  v_data  JSON;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_student_clicks_admin: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.engagement_events e
   WHERE e.user_id = p_user_id;

  SELECT coalesce(json_agg(t), '[]'::json) INTO v_data FROM (
    SELECT
      e.id,
      e.event_type,
      e.occurred_at,
      e.entity_type,
      e.entity_id,
      e.unified_opportunity_id,
      e.destination_url,
      e.event_count,
      e.source,
      -- Nome legível resolvido aqui: a alternativa é o front fazer N+1 ida ao
      -- banco por linha da tabela.
      coalesce(po.name, inst.name) AS entity_name
    FROM public.engagement_events e
    LEFT JOIN public.partner_opportunities po
           ON e.entity_type = 'partner_opportunity' AND po.id = e.entity_id
    LEFT JOIN public.institutions inst
           ON e.entity_type = 'institution' AND inst.id = e.entity_id
    WHERE e.user_id = p_user_id
    ORDER BY e.occurred_at DESC, e.id
    LIMIT p_page_size OFFSET p_page * p_page_size
  ) t;

  RETURN json_build_object('data', v_data, 'count', v_total);
END;
$$;


ALTER FUNCTION "public"."get_student_clicks_admin"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_student_clicks_admin"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) IS 'Eventos de engajamento de um estudante, paginados, para a aba Clicks do modal de atividade (TP-4 4c). Lê engagement_events. Restrita ao backoffice.';



CREATE OR REPLACE FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_result jsonb;
    v_partner_id uuid;
    v_is_admin boolean := false;
    v_has_access boolean := false;
BEGIN
    -- 1. Check if user is admin or belongs to a partner
    SELECT EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = auth.uid() 
        AND permission IN ('Estudantes', 'Dashboard', 'Parceiros')
    ) OR (auth.jwt() ->> 'role' = 'service_role') INTO v_is_admin;
    
    -- Get partner_id if the user is a partner
    SELECT partner_id INTO v_partner_id FROM public.partners_users WHERE user_id = auth.uid() LIMIT 1;

    -- 2. Verify access
    IF v_is_admin THEN
        v_has_access := TRUE;
    ELSE
        -- Access if user is a partner and the student has an application with this partner OR a redirect click
        IF v_partner_id IS NOT NULL THEN
            SELECT EXISTS (
                SELECT 1 FROM public.student_applications WHERE user_id = p_student_id AND partner_id = v_partner_id
                UNION
                SELECT 1 FROM public.external_redirect_clicks WHERE user_id = p_student_id AND partner_id = v_partner_id
            ) INTO v_has_access;
        END IF;
    END IF;

    IF NOT v_has_access THEN
        RAISE EXCEPTION 'Access denied to student details';
    END IF;

    -- 3. Fetch data matching the frontend's expected schema
    SELECT jsonb_build_object(
        'profile', (
            SELECT jsonb_build_object(
                'id', up.id,
                'full_name', up.full_name,
                'email', au.email,
                'phone', au.phone,
                'city', up.city,
                'state', up.state,
                'neighborhood', up.neighborhood,
                'street', up.street,
                'street_number', up.street_number,
                'complement', up.complement,
                'zip_code', up.zip_code,
                'country', up.country,
                'education', up.education,
                'education_year', up.education_year,
                'age', up.age,
                'created_at', up.created_at,
                'is_nubo_student', up.is_nubo_student
            ) FROM public.user_profiles up
            JOIN auth.users au ON au.id = up.id
            WHERE up.id = p_student_id
        ),
        'preferences', (
            SELECT jsonb_build_object(
                'course_interest', course_interest,
                'preferred_shifts', preferred_shifts,
                'university_preference', university_preference,
                'program_preference', program_preference,
                'quota_types', quota_types
            ) FROM public.user_preferences WHERE user_id = p_student_id LIMIT 1
        ),
        'income', (
            SELECT jsonb_build_object(
                'per_capita_income', per_capita_income
            ) FROM public.user_income WHERE user_id = p_student_id LIMIT 1
        ),
        'enem_scores', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', id,
                'year', year,
                'nota_linguagens', nota_linguagens,
                'nota_ciencias_humanas', nota_ciencias_humanas,
                'nota_ciencias_natureza', nota_ciencias_natureza,
                'nota_matematica', nota_matematica,
                'nota_redacao', nota_redacao
            )), '[]'::jsonb) FROM public.user_enem_scores WHERE user_id = p_student_id
        ),
        'favorites', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', uf.id,
                'course_id', uf.course_id,
                'partner_id', uf.partner_id,
                'created_at', uf.created_at,
                'courses', (SELECT jsonb_build_object('name', course_name) FROM public.courses WHERE id = uf.course_id),
                'partners', (SELECT jsonb_build_object('name', name) FROM public.partners WHERE id = uf.partner_id)
            )), '[]'::jsonb) FROM public.user_favorites uf WHERE user_id = p_student_id
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_matches_admin"("p_profile_id" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_total_count BIGINT;
  v_matches JSON;
BEGIN
  SELECT count(*) INTO v_total_count 
  FROM public.user_opportunity_matches 
  WHERE profile_id = p_profile_id;

  SELECT coalesce(json_agg(t.*), '[]'::json) INTO v_matches
  FROM (
    SELECT 
      m.unified_opportunity_id,
      m.match_score,
      COALESCE(v.title, 'Oportunidade') as title,
      COALESCE(v.provider_name, '-') as provider_name
    FROM public.user_opportunity_matches m
    LEFT JOIN public.v_unified_opportunities v ON v.unified_id = m.unified_opportunity_id
    WHERE m.profile_id = p_profile_id
    ORDER BY m.match_score DESC
    LIMIT 20
  ) t;

  RETURN json_build_object('count', v_total_count, 'matches', v_matches);
END;
$$;


ALTER FUNCTION "public"."get_student_matches_admin"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_stats"("filter_full_name" "text" DEFAULT NULL::"text", "filter_city" "text" DEFAULT NULL::"text", "filter_education" "text" DEFAULT NULL::"text", "filter_is_nubo_student" boolean DEFAULT NULL::boolean, "filter_income_min" numeric DEFAULT NULL::numeric, "filter_income_max" numeric DEFAULT NULL::numeric, "filter_quota_types" "text"[] DEFAULT NULL::"text"[], "filter_state" "text" DEFAULT NULL::"text", "filter_age_min" integer DEFAULT NULL::integer, "filter_age_max" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE total_count INTEGER; unique_cities INTEGER; unique_states INTEGER; avg_age NUMERIC; v_sql TEXT;
BEGIN
    v_sql := format('SELECT COUNT(DISTINCT p.id), COUNT(DISTINCT p.city), COUNT(DISTINCT p.state), COALESCE(AVG(p.age) FILTER (WHERE p.age > 0 AND p.age < 120), 0) FROM public.user_profiles p LEFT JOIN public.user_preferences pref ON p.id = pref.user_id WHERE 1=1 %s %s %s %s %s %s %s %s %s %s', 
    CASE WHEN filter_full_name IS NOT NULL AND filter_full_name <> '' THEN ' AND p.full_name ILIKE ' || quote_literal('%' || filter_full_name || '%') ELSE '' END,
    CASE WHEN filter_city IS NOT NULL AND filter_city <> '' THEN ' AND p.city ILIKE ' || quote_literal('%' || filter_city || '%') ELSE '' END,
    CASE WHEN filter_education IS NOT NULL AND filter_education <> '' THEN ' AND p.education ILIKE ' || quote_literal('%' || filter_education || '%') ELSE '' END,
    CASE WHEN filter_is_nubo_student IS NOT NULL THEN ' AND p.is_nubo_student = ' || filter_is_nubo_student::text ELSE '' END,
    CASE WHEN filter_income_min IS NOT NULL THEN ' AND pref.family_income_per_capita >= ' || filter_income_min::text ELSE '' END,
    CASE WHEN filter_income_max IS NOT NULL THEN ' AND pref.family_income_per_capita <= ' || filter_income_max::text ELSE '' END,
    CASE WHEN filter_quota_types IS NOT NULL THEN ' AND pref.quota_types && ' || quote_literal(filter_quota_types::text) || '::text[]' ELSE '' END,
    CASE WHEN filter_state IS NOT NULL THEN ' AND p.state = ' || quote_literal(filter_state) ELSE '' END,
    CASE WHEN filter_age_min IS NOT NULL THEN ' AND p.age >= ' || filter_age_min::text ELSE '' END,
    CASE WHEN filter_age_max IS NOT NULL THEN ' AND p.age <= ' || filter_age_max::text ELSE '' END
    );
    EXECUTE v_sql INTO total_count, unique_cities, unique_states, avg_age;
    RETURN jsonb_build_object('total_students', total_count, 'total_cities', unique_cities, 'total_states', unique_states, 'average_age', ROUND(avg_age, 1));
END; $$;


ALTER FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text" DEFAULT NULL::"text", "p_filter_city" "text" DEFAULT NULL::"text", "p_filter_education" "text" DEFAULT NULL::"text", "p_filter_is_nubo_student" boolean DEFAULT NULL::boolean, "p_filter_income_min" numeric DEFAULT NULL::numeric, "p_filter_income_max" numeric DEFAULT NULL::numeric, "p_filter_quota_types" "text"[] DEFAULT NULL::"text"[], "p_sort_by" "text" DEFAULT 'created_at'::"text", "p_sort_order" "text" DEFAULT 'desc'::"text", "p_filter_state" "text" DEFAULT NULL::"text", "p_filter_age_min" integer DEFAULT NULL::integer, "p_filter_age_max" integer DEFAULT NULL::integer) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $_$
DECLARE
  v_offset INT;
  v_total_count BIGINT;
  v_data JSON;
  v_order_col TEXT;
  v_order_dir TEXT;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_students_paginated: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  v_offset := p_page * p_page_size;

  -- Whitelist das colunas ordenáveis. Os valores são ALIASES DE SAÍDA da
  -- subquery interna, não colunas qualificadas — é o que permite ordenar por
  -- `whatsapp`, que é computada. Qualquer valor fora da lista cai em created_at.
  v_order_col := CASE p_sort_by
    WHEN 'full_name'       THEN 'full_name'
    WHEN 'age'             THEN 'age'
    WHEN 'city'            THEN 'city'
    WHEN 'education'       THEN 'education'
    WHEN 'whatsapp'        THEN 'whatsapp'
    WHEN 'is_nubo_student' THEN 'is_nubo_student'
    WHEN 'created_at'      THEN 'created_at'
    ELSE 'created_at'
  END;

  v_order_dir := CASE WHEN lower(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END;

  -- 1. Contagem total (inalterada — mesmos filtros, mesma semântica)
  SELECT count(DISTINCT p.id) INTO v_total_count
  FROM public.user_profiles p
  LEFT JOIN public.user_income inc ON inc.user_id = p.id
  LEFT JOIN public.user_preferences pref ON p.id = pref.user_id
  WHERE (p_filter_name IS NULL OR p.full_name ILIKE '%' || p_filter_name || '%')
    AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
    AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
    AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
    AND (p_filter_income_min IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) >= p_filter_income_min)
    AND (p_filter_income_max IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) <= p_filter_income_max)
    AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types)
    AND (p_filter_state IS NULL OR p.state = p_filter_state)
    AND (p_filter_age_min IS NULL OR p.age >= p_filter_age_min)
    AND (p_filter_age_max IS NULL OR p.age <= p_filter_age_max);

  -- 2. Página de dados.
  --    Interna: DISTINCT ON (p.id) ORDER BY p.id  — exigência do operador.
  --    Externa: ORDER BY <coluna pedida> + LIMIT/OFFSET — a ordenação real.
  EXECUTE format($fmt$
    SELECT coalesce(json_agg(t.*), '[]'::json)
    FROM (
      SELECT *
      FROM (
        SELECT DISTINCT ON (p.id)
          p.id,
          p.full_name,
          COALESCE(p.phone, au.phone) as whatsapp,
          p.age,
          p.race,
          p.city,
          p.state,
          p.education,
          p.is_nubo_student,
          p.created_at,
          COALESCE(inc.per_capita_income, pref.family_income_per_capita) as per_capita_income,
          pref.quota_types,
          (SELECT COUNT(*) FROM public.student_applications sa WHERE sa.user_id = p.id AND sa.status = 'DRAFT') as draft_applications_count,
          (SELECT STRING_AGG(po.name, ', ') FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id = sa.partner_id WHERE sa.user_id = p.id AND sa.status = 'DRAFT') as draft_applications_list,
          (SELECT COUNT(*) FROM public.student_applications sa WHERE sa.user_id = p.id AND sa.status != 'DRAFT') as completed_applications_count,
          (SELECT STRING_AGG(po.name, ', ') FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id = sa.partner_id WHERE sa.user_id = p.id AND sa.status != 'DRAFT') as completed_applications_list,
          (SELECT COUNT(*) FROM public.user_opportunity_matches m WHERE m.profile_id = p.id) as total_matches,
          (SELECT STRING_AGG(v.title || ' (' || v.provider_name || ') - ' || ROUND(m.match_score) || '%%', '; ')
           FROM (SELECT unified_opportunity_id, match_score FROM public.user_opportunity_matches WHERE profile_id = p.id ORDER BY match_score DESC LIMIT 10) m
           JOIN public.v_unified_opportunities v ON v.unified_id = m.unified_opportunity_id) as matches_list,
          (SELECT STRING_AGG(
            COALESCE(
              v_c.title || ' (' || v_c.provider_name || ')',
              v_p.title || ' (' || v_p.provider_name || ')',
              inst.name
            ), '; ')
           FROM public.user_favorites f
           LEFT JOIN public.v_unified_opportunities v_c ON v_c.unified_id = 'mec_' || f.course_id
           LEFT JOIN public.v_unified_opportunities v_p ON v_p.unified_id = 'partner_' || f.partner_opportunities_id
           LEFT JOIN public.institutions inst ON inst.id = f.institution_id
           WHERE f.user_id = p.id) as favorites_list
        FROM public.user_profiles p
        LEFT JOIN auth.users au ON au.id = p.id
        LEFT JOIN public.user_income inc ON inc.user_id = p.id
        LEFT JOIN public.user_preferences pref ON pref.user_id = p.id
        WHERE
          ($1 IS NULL OR p.full_name ILIKE '%%' || $1 || '%%')
          AND ($2 IS NULL OR p.city ILIKE '%%' || $2 || '%%')
          AND ($3 IS NULL OR p.education ILIKE '%%' || $3 || '%%')
          AND ($4 IS NULL OR p.is_nubo_student = $4)
          AND ($5 IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) >= $5)
          AND ($6 IS NULL OR COALESCE(inc.per_capita_income, pref.family_income_per_capita) <= $6)
          AND ($7 IS NULL OR pref.quota_types && $7)
          AND ($10 IS NULL OR p.state = $10)
          AND ($11 IS NULL OR p.age >= $11)
          AND ($12 IS NULL OR p.age <= $12)
        ORDER BY p.id
      ) d
      ORDER BY %I %s NULLS LAST, d.id
      LIMIT $8
      OFFSET $9
    ) t
  $fmt$, v_order_col, v_order_dir)
  USING
    p_filter_name,
    p_filter_city,
    p_filter_education,
    p_filter_is_nubo_student,
    p_filter_income_min,
    p_filter_income_max,
    p_filter_quota_types,
    p_page_size,
    v_offset,
    p_filter_state,
    p_filter_age_min,
    p_filter_age_max
  INTO v_data;

  RETURN json_build_object('data', v_data, 'count', v_total_count);
END; $_$;


ALTER FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) RETURNS TABLE("t_schema" "text", "t_name" "text", "c_name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT 
    c.table_schema::text as t_schema, 
    c.table_name::text as t_name, 
    c.column_name::text as c_name
  FROM information_schema.columns c
  WHERE c.table_name = ANY(table_names)
    AND c.table_schema IN ('public', 'auth')
  ORDER BY c.table_schema, c.table_name, c.ordinal_position;
$$;


ALTER FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_unified_opportunities_by_distance"("p_lat" double precision, "p_long" double precision) RETURNS TABLE("unified_id" "text", "title" "text", "provider_name" "text", "type" "text", "opportunity_type" "text", "category" "text", "is_partner" boolean, "location" "text", "badges" "jsonb", "created_at" timestamp with time zone, "external_redirect_url" "text", "external_redirect_enabled" boolean, "status" "text", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "match_score" numeric, "institution_cover_url" "text", "nu_vagas_autorizadas" "text", "institution_id" "uuid", "institution_igc" "text", "institution_organization" "text", "institution_category" "text", "institution_site" "text", "eligibility_criteria" "jsonb", "benefits" "jsonb", "brand_color" "text", "weights" "jsonb", "institution_acronym" "text", "latitude" double precision, "longitude" double precision, "min_cutoff_score_current" numeric, "min_cutoff_score_prev" numeric, "max_cutoff_score_current" numeric, "max_cutoff_score_prev" numeric, "qt_vagas_ofertadas_current" "text", "qt_vagas_ofertadas_prev" "text", "qt_inscricao_current" "text", "qt_inscricao_prev" "text", "nu_media_minima_enem_current" numeric, "nu_media_minima_enem_prev" numeric, "vagas_ociosas_current" boolean, "vagas_ociosas_prev" boolean, "search_text" "text", "distance_km" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT v.*,
    CASE
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL
           AND p_lat IS NOT NULL AND p_long IS NOT NULL THEN
        6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
          cos(radians(p_lat)) * cos(radians(v.latitude)) *
          cos(radians(v.longitude) - radians(p_long)) +
          sin(radians(p_lat)) * sin(radians(v.latitude))
        )))
      ELSE NULL
    END AS distance_km
  FROM public.v_unified_opportunities v;
$$;


ALTER FUNCTION "public"."get_unified_opportunities_by_distance"("p_lat" double precision, "p_long" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_unique_course_names"() RETURNS TABLE("course_name" "text")
    LANGUAGE "sql"
    AS $$
  SELECT DISTINCT course_name
  FROM courses
  ORDER BY course_name;
$$;


ALTER FUNCTION "public"."get_unique_course_names"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_favorites"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id UUID;
  v_course_ids UUID[];
  v_partner_ids UUID[];
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT ARRAY_AGG(course_id) INTO v_course_ids
  FROM public.user_favorites
  WHERE user_id = v_user_id AND course_id IS NOT NULL;

  SELECT ARRAY_AGG(partner_id) INTO v_partner_ids
  FROM public.user_favorites
  WHERE user_id = v_user_id AND partner_id IS NOT NULL;

  -- coalesce to empty arrays if null
  IF v_course_ids IS NULL THEN v_course_ids := ARRAY[]::UUID[]; END IF;
  IF v_partner_ids IS NULL THEN v_partner_ids := ARRAY[]::UUID[]; END IF;

  RETURN jsonb_build_object(
    'courseIds', v_course_ids,
    'partnerIds', v_partner_ids
  );
END;
$$;


ALTER FUNCTION "public"."get_user_favorites"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_favorites_details"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id UUID;
  v_courses JSONB;
  v_partners JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Fetch Favorite Courses
  -- We join user_favorites with mv_course_catalog to get all display details efficiently
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', mv.course_id,
      'course_name', mv.course_name,
      'institution_name', mv.institution_name,
      'city', mv.city,
      'state', mv.state,
      'vacancies', mv.vacancies_json,
      'opportunities', mv.opportunities_json
    )
  ) INTO v_courses
  FROM public.user_favorites uf
  JOIN public.mv_course_catalog mv ON uf.course_id = mv.course_id
  WHERE uf.user_id = v_user_id;

  -- Fetch Favorite Partners
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'description', p.description,
      'location', p.location,
      'type', p.type,
      'income', p.income,
      'dates', p.dates,
      'link', p.link,
      'coverimage', p.coverimage
    )
  ) INTO v_partners
  FROM public.user_favorites uf
  JOIN public.partners p ON uf.partner_id = p.id
  WHERE uf.user_id = v_user_id;

  -- Return combined object
  RETURN jsonb_build_object(
    'courses', COALESCE(v_courses, '[]'::jsonb),
    'partners', COALESCE(v_partners, '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."get_user_favorites_details"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.user_profiles (id, referral_source)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'referral_source')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$;


ALTER FUNCTION "public"."handle_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_dashboard_permission"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.user_permissions
        WHERE user_id = auth.uid()
        AND permission = 'Dashboard'
    );
END;
$$;


ALTER FUNCTION "public"."has_dashboard_permission"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_permission"("p_permission" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.user_permissions
        WHERE user_id = auth.uid()
        AND permission = p_permission
    );
END;
$$;


ALTER FUNCTION "public"."has_permission"("p_permission" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."haversine_km"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) RETURNS numeric
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
    SELECT CASE
        WHEN lat1 IS NULL OR lon1 IS NULL OR lat2 IS NULL OR lon2 IS NULL THEN NULL
        ELSE
            (6371.0 * 2 * asin(sqrt(
                sin(radians((lat2 - lat1) / 2.0)) ^ 2
                + cos(radians(lat1)) * cos(radians(lat2))
                * sin(radians((lon2 - lon1) / 2.0)) ^ 2
            )))::numeric
    END;
$$;


ALTER FUNCTION "public"."haversine_km"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."haversine_km"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) IS 'Calcula a distância em KM entre dois pontos usando a fórmula de Haversine. Suporta FLOAT8/NUMERIC.';



CREATE OR REPLACE FUNCTION "public"."import_nubo_students"("students" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    student_record JSONB;
    raw_phone TEXT;
    cleaned_phone TEXT;
    count_imported INTEGER := 0;
    count_updated_users INTEGER := 0;
BEGIN
    FOR student_record IN SELECT * FROM jsonb_array_elements(students)
    LOOP
        -- Extract phone. Case sensitive key match depends on CSV JSON conversion. 
        -- Assuming "Phone" based on CSV header.
        raw_phone := student_record->>'Phone';
        
        IF raw_phone IS NOT NULL AND raw_phone <> '' THEN
            cleaned_phone := public.clean_phone_number(raw_phone);
            
            -- Insert into whitelist (Upsert)
            INSERT INTO public.nubo_student_whitelist (phone_number)
            VALUES (cleaned_phone)
            ON CONFLICT (phone_number) DO NOTHING;
            
            count_imported := count_imported + 1;
        END IF;
    END LOOP;

    -- Update existing user_profiles
    -- This is a heavy query if many users, but safe for batch op.
    -- We update user_profiles where the linked auth.user phone matches the whitelist.
    
    WITH matched_users AS (
        SELECT up.id
        FROM public.user_profiles up
        JOIN auth.users au ON up.id = au.id
        JOIN public.nubo_student_whitelist nsw 
            -- Match: auth phone (cleaned) ends with whitelist number (cleaned)
            ON public.clean_phone_number(au.phone) LIKE '%' || nsw.phone_number
        WHERE up.is_nubo_student IS FALSE
    )
    UPDATE public.user_profiles
    SET is_nubo_student = TRUE
    WHERE id IN (SELECT id FROM matched_users);
    
    GET DIAGNOSTICS count_updated_users = ROW_COUNT;

    RETURN jsonb_build_object(
        'imported_whitelist_entries', count_imported,
        'updated_existing_profiles', count_updated_users
    );
END;
$$;


ALTER FUNCTION "public"."import_nubo_students"("students" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."import_sean_ellis_data"("data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
    row_data JSONB;
    v_submitted_at TIMESTAMPTZ;
    v_full_name TEXT;
    v_whatsapp_raw TEXT;
    v_whatsapp_normalized TEXT;
    v_user_id UUID;
    v_count INTEGER := 0;
BEGIN
    -- Loop through array
    FOR row_data IN SELECT * FROM jsonb_array_elements(data)
    LOOP
        v_full_name := row_data->>'full_name';
        v_whatsapp_raw := row_data->>'whatsapp_raw';
        
        -- Normalize
        v_whatsapp_normalized := public.normalize_whatsapp(v_whatsapp_raw);
        
        -- Find user: try to match normalized number against auth.users phone
        -- Auth phone usually starts with +, keep that in mind
        -- We'll try a few variations
        v_user_id := NULL;
        
        SELECT id INTO v_user_id FROM auth.users 
        WHERE phone = v_whatsapp_normalized 
           OR phone = '+' || v_whatsapp_normalized
           OR phone LIKE '%' || v_whatsapp_normalized
        LIMIT 1;

        -- Insert
        INSERT INTO public.sean_ellis_score (
            submitted_at, 
            full_name, 
            whatsapp_raw, 
            whatsapp_normalized,
            sisu_subscribed, 
            sisu_courses, 
            sisu_status, 
            sisu_cloudinha_influence,
            prouni_subscribed, 
            prouni_courses, 
            prouni_cloudinha_influence, 
            prouni_status,
            disappointment_level, 
            feedback, 
            user_id
        ) VALUES (
            to_timestamp(row_data->>'submitted_at', 'DD/MM/YYYY HH24:MI:SS'),
            v_full_name,
            v_whatsapp_raw,
            v_whatsapp_normalized,
            row_data->>'sisu_subscribed',
            row_data->>'sisu_courses',
            row_data->>'sisu_status',
            row_data->>'sisu_cloudinha_influence',
            row_data->>'prouni_subscribed',
            row_data->>'prouni_courses',
            row_data->>'prouni_cloudinha_influence',
            row_data->>'prouni_status',
            row_data->>'disappointment_level',
            row_data->>'feedback',
            v_user_id
        );
        
        v_count := v_count + 1;
    END LOOP;
    
    RETURN jsonb_build_object('success', true, 'count', v_count);
END;
$$;


ALTER FUNCTION "public"."import_sean_ellis_data"("data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_backoffice_admin"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = auth.uid() 
        AND permission = 'Controle de usuários'
    );
END;
$$;


ALTER FUNCTION "public"."is_backoffice_admin"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."important_dates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "start_date" timestamp with time zone NOT NULL,
    "end_date" timestamp with time zone,
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "controls_opportunity_dates" boolean DEFAULT false NOT NULL,
    "partner_id" "uuid",
    "opportunity_id" "uuid",
    CONSTRAINT "important_dates_type_check" CHECK (("type" = ANY (ARRAY['sisu'::"text", 'prouni'::"text", 'general'::"text", 'partners'::"text"])))
);


ALTER TABLE "public"."important_dates" OWNER TO "postgres";


COMMENT ON COLUMN "public"."important_dates"."controls_opportunity_dates" IS 'Quando true, start_date/end_date desta entrada sao usados como periodo de inscricao das oportunidades MEC do tipo correspondente (sisu/prouni)';



CREATE OR REPLACE FUNCTION "public"."manage_important_date"("p_id" "uuid" DEFAULT NULL::"uuid", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_start_date" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_end_date" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_type" "text" DEFAULT NULL::"text", "p_delete" boolean DEFAULT false, "p_controls_opportunity_dates" boolean DEFAULT NULL::boolean, "p_partner_id" "uuid" DEFAULT NULL::"uuid", "p_opportunity_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."important_dates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_date public.important_dates;
BEGIN
    -- Permission check
    IF NOT EXISTS (
        SELECT 1 FROM public.user_permissions
        WHERE user_id = auth.uid()
        AND permission = 'Calendário'
    ) THEN
        RAISE EXCEPTION 'Acesso negado. Permissão insuficiente.';
    END IF;

    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.important_dates WHERE id = p_id RETURNING * INTO v_date;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
        RETURN v_date;

    ELSIF p_id IS NULL THEN
        INSERT INTO public.important_dates (
            title, description, start_date, end_date, type, controls_opportunity_dates, partner_id, opportunity_id
        )
        VALUES (
            p_title, p_description, p_start_date, p_end_date, p_type, COALESCE(p_controls_opportunity_dates, false), p_partner_id, p_opportunity_id
        )
        RETURNING * INTO v_date;

    ELSE
        UPDATE public.important_dates
        SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            start_date = COALESCE(p_start_date, start_date),
            end_date = COALESCE(p_end_date, end_date),
            type = COALESCE(p_type, type),
            controls_opportunity_dates = COALESCE(p_controls_opportunity_dates, controls_opportunity_dates),
            partner_id = p_partner_id, -- Allow nullifying
            opportunity_id = p_opportunity_id -- Allow nullifying
        WHERE id = p_id
        RETURNING * INTO v_date;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
    END IF;

    RETURN v_date;
END;
$$;


ALTER FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean, "p_controls_opportunity_dates" boolean, "p_partner_id" "uuid", "p_opportunity_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manage_knowledge_document"("p_id" "uuid" DEFAULT NULL::"uuid", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_category_id" "uuid" DEFAULT NULL::"uuid", "p_partner_id" "uuid" DEFAULT NULL::"uuid", "p_storage_path" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean, "p_keywords" "text"[] DEFAULT NULL::"text"[], "p_change_summary" "text" DEFAULT NULL::"text", "p_delete" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_user_id UUID;
    v_doc RECORD;
    v_new_id UUID;
    v_new_version INTEGER;
BEGIN
    -- Auth check: caller must be admin
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.user_permissions WHERE user_id = v_user_id AND permission = 'Conhecimento') THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Insufficient permissions');
    END IF;

    -- DELETE
    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.knowledge_documents WHERE id = p_id;
        RETURN jsonb_build_object('status', 'success', 'action', 'deleted', 'id', p_id);
    END IF;

    -- UPDATE
    IF p_id IS NOT NULL THEN
        -- Fetch current state for versioning
        SELECT * INTO v_doc FROM public.knowledge_documents WHERE id = p_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'error', 'message', 'Document not found');
        END IF;

        -- Save current version to history before updating
        v_new_version := v_doc.current_version + 1;

        INSERT INTO public.knowledge_document_versions (document_id, version_number, storage_path, change_summary, created_by)
        VALUES (p_id, v_new_version, COALESCE(p_storage_path, v_doc.storage_path), p_change_summary, v_user_id);

        -- Update document
        UPDATE public.knowledge_documents SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            category_id = COALESCE(p_category_id, category_id),
            partner_id = p_partner_id,  -- Allow setting to NULL
            storage_path = COALESCE(p_storage_path, storage_path),
            is_active = COALESCE(p_is_active, is_active),
            current_version = v_new_version,
            updated_at = now()
        WHERE id = p_id;

        -- Update keywords if provided
        IF p_keywords IS NOT NULL THEN
            DELETE FROM public.knowledge_keywords WHERE document_id = p_id;
            INSERT INTO public.knowledge_keywords (document_id, keyword)
            SELECT p_id, LOWER(TRIM(kw)) FROM unnest(p_keywords) AS kw
            WHERE TRIM(kw) <> '';
        END IF;

        RETURN jsonb_build_object('status', 'success', 'action', 'updated', 'id', p_id, 'version', v_new_version);
    END IF;

    -- CREATE
    IF p_title IS NOT NULL AND p_storage_path IS NOT NULL THEN
        INSERT INTO public.knowledge_documents (title, description, category_id, partner_id, storage_path, created_by)
        VALUES (p_title, p_description, p_category_id, p_partner_id, p_storage_path, v_user_id)
        RETURNING id INTO v_new_id;

        -- Save version 1
        INSERT INTO public.knowledge_document_versions (document_id, version_number, storage_path, change_summary, created_by)
        VALUES (v_new_id, 1, p_storage_path, 'Versão inicial', v_user_id);

        -- Insert keywords
        IF p_keywords IS NOT NULL THEN
            INSERT INTO public.knowledge_keywords (document_id, keyword)
            SELECT v_new_id, LOWER(TRIM(kw)) FROM unnest(p_keywords) AS kw
            WHERE TRIM(kw) <> '';
        END IF;

        RETURN jsonb_build_object('status', 'success', 'action', 'created', 'id', v_new_id);
    END IF;

    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid parameters: title and storage_path required for creation');
END;
$$;


ALTER FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manage_knowledge_document"("p_id" "uuid" DEFAULT NULL::"uuid", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_category_id" "uuid" DEFAULT NULL::"uuid", "p_partner_id" "uuid" DEFAULT NULL::"uuid", "p_storage_path" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean, "p_keywords" "text"[] DEFAULT NULL::"text"[], "p_change_summary" "text" DEFAULT NULL::"text", "p_delete" boolean DEFAULT false, "p_partner_opportunity_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_user_id UUID;
    v_doc RECORD;
    v_new_id UUID;
    v_new_version INTEGER;
BEGIN
    -- Auth check: caller must be admin
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.user_permissions WHERE user_id = v_user_id AND permission = 'Conhecimento') THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Insufficient permissions');
    END IF;

    -- DELETE
    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.knowledge_documents WHERE id = p_id;
        RETURN jsonb_build_object('status', 'success', 'action', 'deleted', 'id', p_id);
    END IF;

    -- UPDATE
    IF p_id IS NOT NULL THEN
        -- Fetch current state for versioning
        SELECT * INTO v_doc FROM public.knowledge_documents WHERE id = p_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'error', 'message', 'Document not found');
        END IF;

        -- Save current version to history before updating
        v_new_version := v_doc.current_version + 1;

        INSERT INTO public.knowledge_document_versions (document_id, version_number, storage_path, change_summary, created_by)
        VALUES (p_id, v_new_version, COALESCE(p_storage_path, v_doc.storage_path), p_change_summary, v_user_id);

        -- Update document
        UPDATE public.knowledge_documents SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            category_id = COALESCE(p_category_id, category_id),
            partner_id = p_partner_id,  -- Allow setting to NULL
            storage_path = COALESCE(p_storage_path, storage_path),
            is_active = COALESCE(p_is_active, is_active),
            current_version = v_new_version,
            updated_at = now()
        WHERE id = p_id;

        -- Update keywords if provided
        IF p_keywords IS NOT NULL THEN
            DELETE FROM public.knowledge_keywords WHERE document_id = p_id;
            INSERT INTO public.knowledge_keywords (document_id, keyword)
            SELECT p_id, LOWER(TRIM(kw)) FROM unnest(p_keywords) AS kw
            WHERE TRIM(kw) <> '';
        END IF;

        -- Sync N:N opportunities if provided
        IF p_partner_opportunity_ids IS NOT NULL THEN
            DELETE FROM public.knowledge_document_opportunities WHERE document_id = p_id;
            INSERT INTO public.knowledge_document_opportunities (document_id, partner_opportunity_id)
            SELECT p_id, opp_id FROM unnest(p_partner_opportunity_ids) AS opp_id
            ON CONFLICT DO NOTHING;
        END IF;

        RETURN jsonb_build_object('status', 'success', 'action', 'updated', 'id', p_id, 'version', v_new_version);
    END IF;

    -- CREATE
    IF p_title IS NOT NULL AND p_storage_path IS NOT NULL THEN
        INSERT INTO public.knowledge_documents (title, description, category_id, partner_id, storage_path, created_by)
        VALUES (p_title, p_description, p_category_id, p_partner_id, p_storage_path, v_user_id)
        RETURNING id INTO v_new_id;

        -- Save version 1
        INSERT INTO public.knowledge_document_versions (document_id, version_number, storage_path, change_summary, created_by)
        VALUES (v_new_id, 1, p_storage_path, 'Versão inicial', v_user_id);

        -- Insert keywords
        IF p_keywords IS NOT NULL THEN
            INSERT INTO public.knowledge_keywords (document_id, keyword)
            SELECT v_new_id, LOWER(TRIM(kw)) FROM unnest(p_keywords) AS kw
            WHERE TRIM(kw) <> '';
        END IF;

        -- Insert N:N opportunities
        IF p_partner_opportunity_ids IS NOT NULL THEN
            INSERT INTO public.knowledge_document_opportunities (document_id, partner_opportunity_id)
            SELECT v_new_id, opp_id FROM unnest(p_partner_opportunity_ids) AS opp_id
            ON CONFLICT DO NOTHING;
        END IF;

        RETURN jsonb_build_object('status', 'success', 'action', 'created', 'id', v_new_id);
    END IF;

    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid parameters: title and storage_path required for creation');
END;
$$;


ALTER FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean, "p_partner_opportunity_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manage_partner"("p_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_location" "text" DEFAULT NULL::"text", "p_type" "text" DEFAULT NULL::"text", "p_income" "text" DEFAULT NULL::"text", "p_dates" "jsonb" DEFAULT NULL::"jsonb", "p_link" "text" DEFAULT NULL::"text", "p_coverimage" "text" DEFAULT NULL::"text", "p_applications_open" boolean DEFAULT true, "p_delete" boolean DEFAULT false) RETURNS "public"."partners"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_partner public.partners;
BEGIN
    -- Permission check: Only users with 'Dashboard' permission can manage partners
    IF NOT EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = auth.uid() 
        AND permission = 'Dashboard'
    ) THEN
        RAISE EXCEPTION 'Acesso negado. Permissão insuficiente.';
    END IF;

    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.partners WHERE id = p_id RETURNING * INTO v_partner;
    ELSIF p_id IS NULL THEN
        -- Create new partner
        INSERT INTO public.partners (
            name, 
            description, 
            location, 
            type, 
            income, 
            dates, 
            link, 
            coverimage,
            applications_open
        )
        VALUES (
            p_name, 
            p_description, 
            p_location, 
            p_type, 
            p_income, 
            p_dates, 
            p_link, 
            p_coverimage,
            COALESCE(p_applications_open, true)
        )
        RETURNING * INTO v_partner;
    ELSE
        -- Update existing partner
        UPDATE public.partners
        SET 
            name = COALESCE(p_name, name),
            description = COALESCE(p_description, description),
            location = COALESCE(p_location, location),
            type = COALESCE(p_type, type),
            income = COALESCE(p_income, income),
            dates = COALESCE(p_dates, dates),
            link = COALESCE(p_link, link),
            coverimage = COALESCE(p_coverimage, coverimage),
            applications_open = COALESCE(p_applications_open, applications_open),
            updated_at = NOW()
        WHERE id = p_id
        RETURNING * INTO v_partner;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parceiro não encontrado.';
        END IF;
    END IF;

    RETURN v_partner;
END;
$$;


ALTER FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manage_partner"("p_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_location" "text" DEFAULT NULL::"text", "p_type" "text" DEFAULT NULL::"text", "p_income" "text" DEFAULT NULL::"text", "p_dates" "jsonb" DEFAULT NULL::"jsonb", "p_link" "text" DEFAULT NULL::"text", "p_coverimage" "text" DEFAULT NULL::"text", "p_applications_open" boolean DEFAULT NULL::boolean, "p_delete" boolean DEFAULT false, "p_external_redirect_config" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."partners"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_partner public.partners;
BEGIN
    -- Permission check: Only users with 'Dashboard' permission can manage partners
    IF NOT EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = auth.uid() 
        AND permission = 'Dashboard'
    ) THEN
        RAISE EXCEPTION 'Acesso negado. Permissão insuficiente.';
    END IF;

    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.partners WHERE id = p_id RETURNING * INTO v_partner;
    ELSIF p_id IS NULL THEN
        -- Create new partner
        INSERT INTO public.partners (
            name, 
            description, 
            location, 
            type, 
            income, 
            dates, 
            link, 
            coverimage,
            applications_open,
            external_redirect_config
        )
        VALUES (
            p_name, 
            p_description, 
            p_location, 
            p_type, 
            p_income, 
            p_dates, 
            p_link, 
            p_coverimage,
            COALESCE(p_applications_open, true),
            p_external_redirect_config
        )
        RETURNING * INTO v_partner;
    ELSE
        -- Update existing partner
        UPDATE public.partners
        SET 
            name = COALESCE(p_name, name),
            description = COALESCE(p_description, description),
            location = COALESCE(p_location, location),
            type = COALESCE(p_type, type),
            income = COALESCE(p_income, income),
            dates = COALESCE(p_dates, dates),
            link = COALESCE(p_link, link),
            coverimage = COALESCE(p_coverimage, coverimage),
            applications_open = COALESCE(p_applications_open, applications_open),
            external_redirect_config = COALESCE(p_external_redirect_config, external_redirect_config),
            updated_at = NOW()
        WHERE id = p_id
        RETURNING * INTO v_partner;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parceiro não encontrado.';
        END IF;
    END IF;

    RETURN v_partner;
END;
$$;


ALTER FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean, "p_external_redirect_config" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) RETURNS TABLE("id" "uuid", "content" "text", "metadata" "jsonb", "similarity" double precision)
    LANGUAGE "plpgsql"
    AS $$
begin
  return query
  select
    documents.id,
    documents.content,
    documents.metadata,
    1 - (documents.embedding <=> query_embedding) as similarity
  from documents
  where 1 - (documents.embedding <=> query_embedding) > match_threshold
  order by similarity desc
  limit match_count;
end;
$$;


ALTER FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "page_number" integer, "page_size" integer) RETURNS TABLE("course_id" "uuid", "course_name" "text", "institution_name" "text", "campus_city" "text", "campus_state" "text", "distance_km" numeric, "opportunity_id" "uuid", "scholarship_type" "text", "concurrency_type" "text", "cutoff_score" numeric, "shift" "text", "concurrency_tags" "jsonb", "opportunity_type" "text", "institution_igc" numeric, "nota_ponderada" numeric, "score_year" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_base_enem_score numeric;
BEGIN
  -- Force Index Usage
  SET LOCAL enable_seqscan = off;

  -- 1. Get base score from preferences
  SELECT enem_score INTO v_base_enem_score 
  FROM user_preferences 
  WHERE user_id = p_user_id;

  RETURN QUERY
  WITH matching_opportunities AS (
    SELECT 
      o.id as opp_id,
      o.course_id,
      o.scholarship_type,
      o.concurrency_type,
      o.cutoff_score,
      o.shift,
      o.concurrency_tags,
      o.opportunity_type,
      c.course_name,
      c.campus_id
    FROM opportunities o
    JOIN courses c ON o.course_id = c.id
    WHERE 
      o.semester = '1'
      
      -- Focus on ProUni 2025 (or Sisu 2026 if requested)
      AND (
        (program_preference ILIKE '%sisu%' AND o.opportunity_type = 'sisu' AND o.year = 2026) 
        OR
        ((program_preference ILIKE '%prouni%' OR program_preference IS NULL OR program_preference = 'indiferente') AND o.opportunity_type = 'prouni' AND o.year = 2025)
      )

      -- Shift Filter
      AND (
        preferred_shifts IS NULL 
        OR cardinality(preferred_shifts) = 0 
        OR o.shift = ANY(preferred_shifts)
      )
      
      -- Income Logic for ProUni
      AND (
         income_per_capita IS NULL OR
         o.opportunity_type <> 'prouni' OR
         NOT (
           (income_per_capita > 4554 AND ( -- > 3 MW
              o.scholarship_type ILIKE '%Parcial%' OR o.scholarship_type ILIKE '%Integral%'
           ))
           OR
           (income_per_capita > 2277 AND ( -- > 1.5 MW
              o.scholarship_type ILIKE '%Integral%'
           ))
         )
      )

      -- Quota Logic (ProUni Specific)
      AND (
        quota_types IS NULL OR cardinality(quota_types) = 0
        OR o.opportunity_type <> 'prouni'
        OR (
           COALESCE(o.concurrency_tags, '[]'::jsonb)::text ILIKE '%"AMPLA_CONCORRENCIA"%'
           OR 
           EXISTS (
             SELECT 1 FROM unnest(quota_types) q
             WHERE COALESCE(o.concurrency_tags, '[]'::jsonb)::text ILIKE '%"' || q || '"%'
           )
        )
      )
      
      -- Course Filter (ILIKE Search)
      AND (
        course_interests IS NULL 
        OR cardinality(course_interests) = 0
        OR EXISTS (
            SELECT 1 FROM unnest(course_interests) AS interest
            WHERE c.course_name ILIKE '%' || interest || '%'
        )
      )

      -- Location Filters (City/State)
      AND (
        state_names IS NULL 
        OR cardinality(state_names) = 0
        OR EXISTS (
            SELECT 1 FROM campus cp WHERE cp.id = c.campus_id
            AND (
                cp.state ILIKE ANY(SELECT unnest(state_names))
                OR
                cp.state IN (SELECT uf FROM states WHERE name ILIKE ANY(SELECT unnest(state_names)))
            )
        )
      )
      AND (
        city_names IS NULL 
        OR cardinality(city_names) = 0
        OR EXISTS (
            SELECT 1 FROM campus cp WHERE cp.id = c.campus_id
            AND f_unaccent(cp.city) ILIKE ANY(SELECT f_unaccent(unnest(city_names)))
        )
      )
      
      -- SCORE MATCH (Basic ProUni Logic)
      -- Show if: 
      -- 1. No cutoff score exists (rare)
      -- 2. User has no score (Exploratory mode)
      -- 3. User score >= Cutoff
      AND (
        o.cutoff_score IS NULL 
        OR v_base_enem_score IS NULL 
        OR v_base_enem_score >= o.cutoff_score
      )
  )
  
  SELECT
    c.id as course_id, c.course_name, i.name as institution_name,
    cp.city as campus_city, cp.state as campus_state,
    CASE 
        WHEN user_lat IS NOT NULL AND user_long IS NOT NULL 
             AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL THEN
          (point(cp.longitude, cp.latitude) <@> point(user_long, user_lat)) * 1.60934
        ELSE NULL 
    END as distance_km,
    
    mo.opp_id as opportunity_id, mo.scholarship_type, mo.concurrency_type,
    mo.cutoff_score, mo.shift, mo.concurrency_tags, mo.opportunity_type,
    NULLIF(info.igc, '')::numeric as institution_igc,
    
    COALESCE(v_base_enem_score, 0) as nota_ponderada,
    0 as score_year

  FROM matching_opportunities mo
  JOIN courses c ON mo.course_id = c.id
  JOIN campus cp ON c.campus_id = cp.id
  JOIN institutions i ON cp.institution_id = i.id
  LEFT JOIN (
      SELECT DISTINCT ON (institution_id) *
      FROM institutions_info_emec
      ORDER BY institution_id, id DESC
  ) info ON i.id = info.institution_id
  
  ORDER BY
    -- Prioritize results user actually qualifies for (if score exists)
    CASE WHEN v_base_enem_score >= mo.cutoff_score THEN 1 ELSE 0 END DESC,
    
    -- Then standard ordering
    (COALESCE(v_base_enem_score, 0) - COALESCE(mo.cutoff_score, 0)) DESC NULLS LAST,
    distance_km ASC NULLS LAST,
    info.igc DESC NULLS LAST,
    c.course_name ASC
  LIMIT page_size OFFSET page_number * page_size;
END;
$$;


ALTER FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "page_number" integer, "page_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_opportunities"("p_user_id" "uuid" DEFAULT NULL::"uuid", "course_interests" "text"[] DEFAULT NULL::"text"[], "income_per_capita" numeric DEFAULT NULL::numeric, "quota_types" "text"[] DEFAULT NULL::"text"[], "preferred_shifts" "text"[] DEFAULT NULL::"text"[], "program_preference" "text" DEFAULT NULL::"text", "user_lat" double precision DEFAULT NULL::double precision, "user_long" double precision DEFAULT NULL::double precision, "city_names" "text"[] DEFAULT NULL::"text"[], "page_size" integer DEFAULT 10, "page_number" integer DEFAULT 0, "state_names" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("course_id" "uuid", "course_name" "text", "institution_name" "text", "campus_city" "text", "campus_state" "text", "distance_km" double precision, "opportunity_id" "uuid", "scholarship_type" "text", "concurrency_type" "text", "cutoff_score" numeric, "shift" "text", "concurrency_tags" "jsonb", "opportunity_type" "text", "institution_igc" numeric, "nota_ponderada" numeric, "score_year" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_base_enem_score numeric;
BEGIN
  -- Force Index Usage
  SET LOCAL enable_seqscan = off;

  -- 1. Get base score from preferences
  SELECT enem_score INTO v_base_enem_score 
  FROM user_preferences 
  WHERE user_id = p_user_id;

  RETURN QUERY
  WITH matching_opportunities AS (
    SELECT 
      o.id as opp_id,
      o.course_id,
      o.scholarship_type,
      o.concurrency_type,
      o.cutoff_score,
      o.shift,
      o.concurrency_tags,
      o.opportunity_type,
      c.course_name,
      c.campus_id
    FROM opportunities o
    JOIN courses c ON o.course_id = c.id
    WHERE 
      o.semester = '1'
      
      -- Focus on ProUni 2025 (or Sisu 2026 if requested)
      AND (
        (program_preference ILIKE '%sisu%' AND o.opportunity_type = 'sisu' AND o.year = 2026) 
        OR
        ((program_preference ILIKE '%prouni%' OR program_preference IS NULL OR program_preference = 'indiferente') AND o.opportunity_type = 'prouni' AND o.year = 2025)
      )

      -- Shift Filter
      AND (
        preferred_shifts IS NULL 
        OR cardinality(preferred_shifts) = 0 
        OR o.shift = ANY(preferred_shifts)
      )
      
      -- Income Logic for ProUni
      AND (
         income_per_capita IS NULL OR
         o.opportunity_type <> 'prouni' OR
         NOT (
            (income_per_capita > 2277 AND ( -- Qualifying for Integral (up to 1.5 MW)
               o.scholarship_type ILIKE '%Integral%'
            ) AND income_per_capita <= 4554) -- Actually logic should be simpler
            -- Simplified Income Filter:
            -- If user income > 1.5 MW (2277), hide Integral.
            -- If user income > 3.0 MW (4554), hide both (they shouldn't even be here but safe to filter).
            OR
            (income_per_capita > 2277 AND o.scholarship_type ILIKE '%Integral%')
         )
      )

      -- Quota Logic (ProUni Specific)
      AND (
        quota_types IS NULL OR cardinality(quota_types) = 0
        OR o.opportunity_type = 'prouni' -- PROUNI HAS NO TAGS IN PROD DATA
        OR (
           COALESCE(o.concurrency_tags, '[]'::jsonb)::text ILIKE '%"AMPLA_CONCORRENCIA"%'
           OR 
           EXISTS (
             SELECT 1 FROM unnest(quota_types) q
             WHERE COALESCE(o.concurrency_tags, '[]'::jsonb)::text ILIKE '%"' || q || '"%'
           )
        )
      )
      
      -- Course Filter (ILIKE Search)
      AND (
        course_interests IS NULL 
        OR cardinality(course_interests) = 0
        OR EXISTS (
            SELECT 1 FROM unnest(course_interests) AS interest
            WHERE c.course_name ILIKE '%' || interest || '%'
        )
      )

      -- Location Filters (City/State)
      AND (
        state_names IS NULL 
        OR cardinality(state_names) = 0
        OR EXISTS (
            SELECT 1 FROM campus cp WHERE cp.id = c.campus_id
            AND (
                cp.state ILIKE ANY(SELECT unnest(state_names))
                OR
                cp.state IN (SELECT uf FROM states WHERE name ILIKE ANY(SELECT unnest(state_names)))
            )
        )
      )
      AND (
        city_names IS NULL 
        OR cardinality(city_names) = 0
        OR EXISTS (
            SELECT 1 FROM campus cp WHERE cp.id = c.campus_id
            AND f_unaccent(cp.city) ILIKE ANY(SELECT f_unaccent(unnest(city_names)))
        )
      )
      
      -- SCORE MATCH (Basic ProUni Logic)
      AND (
        o.cutoff_score IS NULL 
        OR v_base_enem_score IS NULL 
        OR v_base_enem_score >= o.cutoff_score
      )
  )
  
  SELECT
    c.id as course_id, c.course_name, i.name as institution_name,
    cp.city as campus_city, cp.state as campus_state,
    0.0::double precision as distance_km, -- Fixed: Must match double precision signature
    
    mo.opp_id as opportunity_id, mo.scholarship_type, mo.concurrency_type,
    mo.cutoff_score, mo.shift, mo.concurrency_tags, mo.opportunity_type,
    0.0 as institution_igc, -- Removed brittle numeric conversion
    
    COALESCE(v_base_enem_score, 0) as nota_ponderada,
    0 as score_year

  FROM matching_opportunities mo
  JOIN courses c ON mo.course_id = c.id
  JOIN campus cp ON c.campus_id = cp.id
  JOIN institutions i ON cp.institution_id = i.id
  
  ORDER BY
    CASE WHEN v_base_enem_score >= mo.cutoff_score THEN 1 ELSE 0 END DESC,
    (COALESCE(v_base_enem_score, 0) - COALESCE(mo.cutoff_score, 0)) DESC NULLS LAST,
    c.course_name ASC
  LIMIT page_size OFFSET page_number * page_size;
END;
$$;


ALTER FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "course_interests" "text"[], "income_per_capita" numeric, "quota_types" "text"[], "preferred_shifts" "text"[], "program_preference" "text", "user_lat" double precision, "user_long" double precision, "city_names" "text"[], "page_size" integer, "page_number" integer, "state_names" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_whatsapp"("phone" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    clean_phone TEXT;
BEGIN
    -- Remove non-digits
    clean_phone := regexp_replace(phone, '\D', '', 'g');
    
    -- Basic logic for BR numbers
    -- If 10 or 11 digits, assume BR and add 55
    IF length(clean_phone) BETWEEN 10 AND 11 THEN
        clean_phone := '55' || clean_phone;
    END IF;
    
    RETURN clean_phone;
END;
$$;


ALTER FUNCTION "public"."normalize_whatsapp"("phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pre_fill_application"("p_user_id" "uuid", "p_partner_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
    v_answers JSONB := '{}'::jsonb;
    v_form_record RECORD;
    v_profile_record RECORD;
    v_preferences_record RECORD;
    v_value JSONB;
    v_application_id UUID;
BEGIN
    -- Get user profile
    SELECT * INTO v_profile_record FROM public.user_profiles WHERE id = p_user_id;
    
    -- Get user preferences
    SELECT * INTO v_preferences_record FROM public.user_preferences WHERE user_id = p_user_id;

    -- Iterate through partner_forms for this specific partner where mapping_source exists
    FOR v_form_record IN 
        SELECT field_name, mapping_source 
        FROM public.partner_forms 
        WHERE partner_id = p_partner_id AND mapping_source IS NOT NULL
    LOOP
        v_value := NULL;
        
        -- Dynamically extract from mapping source
        IF v_form_record.mapping_source LIKE 'user_profiles.%' THEN
            EXECUTE format('SELECT to_jsonb($1.%I)', split_part(v_form_record.mapping_source, '.', 2)) 
            INTO v_value USING v_profile_record;
        ELSIF v_form_record.mapping_source LIKE 'user_preferences.%' THEN
            EXECUTE format('SELECT to_jsonb($1.%I)', split_part(v_form_record.mapping_source, '.', 2)) 
            INTO v_value USING v_preferences_record;
        ELSIF v_form_record.mapping_source LIKE 'auth.users.%' THEN
            -- Special handling for auth.users (restricted schema)
            IF v_form_record.mapping_source = 'auth.users.phone' THEN
                SELECT to_jsonb(u.phone) INTO v_value FROM auth.users u WHERE u.id = p_user_id;
            ELSIF v_form_record.mapping_source = 'auth.users.email' THEN
                 SELECT to_jsonb(u.email) INTO v_value FROM auth.users u WHERE u.id = p_user_id;
            END IF;
        END IF;

        IF v_value IS NOT NULL THEN
            -- Add to the answers JSONB object
            v_answers := jsonb_set(v_answers, ARRAY[v_form_record.field_name], v_value);
        END IF;
    END LOOP;

    -- Insert into student_applications
    INSERT INTO public.student_applications (user_id, partner_id, answers, status)
    VALUES (p_user_id, p_partner_id, v_answers, 'DRAFT')
    RETURNING id INTO v_application_id;

    RETURN v_application_id;
END;
$_$;


ALTER FUNCTION "public"."pre_fill_application"("p_user_id" "uuid", "p_partner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_mec_campus_csv"("p_records" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_record         jsonb;
  v_institution_id uuid;
  v_processed      integer := 0;
  v_errors         jsonb   := '[]'::jsonb;
BEGIN
  FOR v_record IN SELECT jsonb_array_elements(p_records)
  LOOP
    BEGIN
      -- Resolve institution via external_code (Gap 2 resolution)
      SELECT id INTO v_institution_id
      FROM institutions
      WHERE external_code = v_record->>'institution_external_code';

      IF v_institution_id IS NULL THEN
        RAISE EXCEPTION 'Institution not found for external_code: %', v_record->>'institution_external_code';
      END IF;

      INSERT INTO campus (institution_id, name, city, state, latitude, longitude)
      VALUES (
        v_institution_id,
        v_record->>'name',
        v_record->>'city',
        v_record->>'state',
        NULLIF(v_record->>'latitude',  '')::double precision,
        NULLIF(v_record->>'longitude', '')::double precision
      )
      ON CONFLICT (institution_id, name, city)
      DO UPDATE SET
        state     = EXCLUDED.state,
        latitude  = COALESCE(EXCLUDED.latitude,  campus.latitude),
        longitude = COALESCE(EXCLUDED.longitude, campus.longitude);

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'record', v_record,
          'error',  SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'errors',    v_errors
  );
END;
$$;


ALTER FUNCTION "public"."process_mec_campus_csv"("p_records" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_mec_courses_csv"("p_records" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_record    jsonb;
  v_course_id uuid;
  v_processed integer := 0;
  v_errors    jsonb   := '[]'::jsonb;
BEGIN
  FOR v_record IN SELECT jsonb_array_elements(p_records)
  LOOP
    BEGIN
      -- Upsert course by campus_id + course_name
      INSERT INTO courses (campus_id, course_name)
      VALUES (
        (v_record->>'campus_id')::uuid,
        v_record->>'course_name'
      )
      ON CONFLICT (campus_id, course_name) DO NOTHING
      RETURNING id INTO v_course_id;

      -- If conflict, fetch existing id
      IF v_course_id IS NULL THEN
        SELECT id INTO v_course_id
        FROM courses
        WHERE campus_id   = (v_record->>'campus_id')::uuid
          AND course_name = v_record->>'course_name';
      END IF;

      -- Insert opportunity (idempotent: skip if same course/type/year/semester/shift exists)
      INSERT INTO opportunities (
        course_id,
        opportunity_type,
        year,
        semester,
        shift,
        cutoff_score,
        scholarship_type
      )
      VALUES (
        v_course_id,
        v_record->>'opportunity_type',
        (v_record->>'year')::integer,
        v_record->>'semester',
        v_record->>'shift',
        NULLIF(v_record->>'cutoff_score', '')::numeric,
        v_record->>'scholarship_type'
      )
      ON CONFLICT (course_id, opportunity_type, year, semester, shift) DO NOTHING;

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'record', v_record,
          'error',  SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'errors',    v_errors
  );
END;
$$;


ALTER FUNCTION "public"."process_mec_courses_csv"("p_records" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_mec_institutions_csv"("p_records" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_record    jsonb;
  v_processed integer := 0;
  v_errors    jsonb   := '[]'::jsonb;
BEGIN
  FOR v_record IN SELECT jsonb_array_elements(p_records)
  LOOP
    BEGIN
      INSERT INTO institutions (name, external_code)
      VALUES (
        v_record->>'name',
        v_record->>'external_code'
      )
      ON CONFLICT (external_code) WHERE external_code IS NOT NULL
      DO UPDATE SET
        name = EXCLUDED.name;

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'record', v_record,
          'error',  SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'errors',    v_errors
  );
END;
$$;


ALTER FUNCTION "public"."process_mec_institutions_csv"("p_records" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid" DEFAULT NULL::"uuid", "p_unified_opportunity_id" "text" DEFAULT NULL::"text", "p_source" "text" DEFAULT 'card'::"text", "p_anonymous_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  c_max_per_hour CONSTANT INT := 300;

  v_user      UUID := auth.uid();
  v_anonymous TEXT := nullif(btrim(coalesce(p_anonymous_id, '')), '');
  v_event_id  TEXT := nullif(btrim(coalesce(p_event_id, '')), '');
  v_recent    INT;
  v_inserted  INT := 0;
BEGIN
  IF v_user IS NULL AND v_anonymous IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'subject');
  END IF;

  IF v_event_id IS NULL OR length(v_event_id) > 500 THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'event_id');
  END IF;

  IF p_entity_type NOT IN ('partner_opportunity', 'mec_opportunity') THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'entity_type');
  END IF;

  IF p_entity_id IS NULL
     AND nullif(btrim(coalesce(p_unified_opportunity_id, '')), '') IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'entity');
  END IF;

  SELECT count(*) INTO v_recent
    FROM public.engagement_events
   WHERE event_type = 'card_click'
     AND entity_type IN ('partner_opportunity', 'mec_opportunity')
     AND occurred_at > now() - interval '1 hour'
     AND (
       (v_user IS NOT NULL AND user_id = v_user)
       OR (v_user IS NULL AND anonymous_id = v_anonymous)
     );

  IF v_recent >= c_max_per_hour THEN
    RETURN jsonb_build_object('status', 'throttled', 'inserted', 0);
  END IF;

  INSERT INTO public.engagement_events (
    event_id,
    event_type,
    occurred_at,
    user_id,
    anonymous_id,
    entity_type,
    entity_id,
    unified_opportunity_id,
    source,
    event_count
  ) VALUES (
    v_event_id,
    'card_click',
    now(),
    v_user,
    v_anonymous,
    p_entity_type,
    p_entity_id,
    nullif(btrim(coalesce(p_unified_opportunity_id, '')), ''),
    left(coalesce(nullif(btrim(coalesce(p_source, '')), ''), 'card'), 120),
    1
  )
  ON CONFLICT (event_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_inserted = 1 THEN 'created' ELSE 'duplicate' END,
    'inserted', v_inserted
  );
END;
$$;


ALTER FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_unified_opportunity_id" "text", "p_source" "text", "p_anonymous_id" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_unified_opportunity_id" "text", "p_source" "text", "p_anonymous_id" "text") IS 'Ingestão validada de card_click para usuário autenticado ou sessão anônima. Idempotente por event_id e limitada por sujeito.';



CREATE OR REPLACE FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  -- Uma tela de catálogo mostra ~15 cards. Rolar por meia hora gera algumas
  -- centenas de views legítimas. 600/h dá folga e ainda barra automação.
  c_max_per_hour CONSTANT INT := 600;
  c_max_batch    CONSTANT INT := 50;

  v_user      UUID := auth.uid();
  v_subject   TEXT;
  v_recent    INT;
  v_inserted  INT := 0;
BEGIN
  IF jsonb_typeof(p_views) <> 'array' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  -- Um lote gigante é sinal de automação, não de navegação.
  IF jsonb_array_length(p_views) > c_max_batch THEN
    RETURN jsonb_build_object('status', 'batch_too_large');
  END IF;

  -- Autenticado é identificado pelo próprio id; anônimo, pela sessão.
  v_subject := coalesce(v_user::text, nullif(btrim(coalesce(p_anonymous_id, '')), ''));
  IF v_subject IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT count(*) INTO v_recent
    FROM public.engagement_events
   WHERE event_type = 'card_view'
     AND occurred_at > now() - interval '1 hour'
     AND (
       (v_user IS NOT NULL AND user_id = v_user)
       OR (v_user IS NULL AND anonymous_id = p_anonymous_id)
     );

  IF v_recent >= c_max_per_hour THEN
    RETURN jsonb_build_object('status', 'throttled', 'inserted', 0);
  END IF;

  -- A deduplicação real é o UNIQUE em event_id: o cliente monta a chave com
  -- sessão + entidade + janela de tempo, então rolar a mesma lista para cima e
  -- para baixo na mesma janela não multiplica o evento.
  WITH incoming AS (
    SELECT
      v.value ->> 'event_id'    AS event_id,
      v.value ->> 'entity_type' AS entity_type,
      nullif(v.value ->> 'entity_id', '')::uuid AS entity_id,
      nullif(v.value ->> 'unified_opportunity_id', '') AS unified_opportunity_id,
      coalesce(v.value ->> 'surface', 'unknown') AS surface
    FROM jsonb_array_elements(p_views) AS v(value)
  ),
  valid AS (
    SELECT * FROM incoming
     WHERE event_id IS NOT NULL
       AND entity_type IN ('partner_opportunity', 'mec_opportunity', 'institution', 'course')
       AND (entity_id IS NOT NULL OR unified_opportunity_id IS NOT NULL)
  ),
  ins AS (
    INSERT INTO public.engagement_events (
      event_id, event_type, occurred_at, user_id, anonymous_id,
      entity_type, entity_id, unified_opportunity_id, source, event_count
    )
    SELECT
      valid.event_id, 'card_view', now(), v_user,
      -- anonymous_id é gravado mesmo para autenticado: é o que permite ligar a
      -- navegação anterior ao login quando a costura roda.
      nullif(btrim(coalesce(p_anonymous_id, '')), ''),
      valid.entity_type, valid.entity_id, valid.unified_opportunity_id,
      'view:' || valid.surface, 1
    FROM valid
    ON CONFLICT (event_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM ins;

  RETURN jsonb_build_object('status', 'ok', 'inserted', v_inserted);
END;
$$;


ALTER FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text") IS 'Ingestão em lote de card_view (TP-2 2a t2). Aceita autenticado e anônimo. A semântica de visibilidade (>=50% por >=1s) é detectada no cliente; aqui se garante deduplicação por event_id, teto de lote e rate limit por hora. Uma tela com 15 cards faz UMA chamada.';



CREATE OR REPLACE FUNCTION "public"."refresh_unified_opportunities"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY v_unified_opportunities;
END;
$$;


ALTER FUNCTION "public"."refresh_unified_opportunities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  -- Um humano não clica em 30 links rastreados diferentes numa hora. O teto é
  -- ordens de grandeza acima do uso legítimo e só morde em abuso.
  c_max_per_hour CONSTANT INT := 30;

  v_link     RECORD;
  v_event_id TEXT;
  v_recent   INT;
BEGIN
  IF p_anonymous_id IS NULL OR btrim(p_anonymous_id) = '' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT l.id, l.code, l.destination_path, l.archived_at,
         l.utm_source, l.utm_medium, l.utm_campaign, l.utm_content, l.utm_term
    INTO v_link
    FROM public.channel_links l
   WHERE l.code = p_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  SELECT count(*) INTO v_recent
    FROM public.engagement_events
   WHERE anonymous_id = p_anonymous_id
     AND entity_type = 'channel_link'
     AND occurred_at > now() - interval '1 hour';

  v_event_id := coalesce(nullif(btrim(coalesce(p_event_id, '')), ''),
                         'link:' || v_link.id::text || ':' || p_anonymous_id || ':' ||
                         to_char(now(), 'YYYYMMDDHH24MISSMS'));

  -- Acima do teto: RESOLVE MESMO ASSIM, só não registra.
  -- Devolver 'rate_limited' mandaria a pessoa para a home. Se por trás do abuso
  -- houver um visitante real — NAT corporativo, escola, lan house — punir a
  -- navegação dele para proteger uma métrica é a troca errada. Perde-se o
  -- evento, não a visita.
  IF v_recent < c_max_per_hour THEN
    INSERT INTO public.engagement_events (
      event_id, event_type, occurred_at, anonymous_id,
      entity_type, channel_link_id, source, event_count
    ) VALUES (
      v_event_id, 'card_click', now(), p_anonymous_id,
      'channel_link', v_link.id, 'redirect_route', 1
    )
    ON CONFLICT (event_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'status',           'ok',
    'link_id',          v_link.id,
    'destination_path', coalesce(v_link.destination_path, '/'),
    'archived',         v_link.archived_at IS NOT NULL,
    'throttled',        v_recent >= c_max_per_hour,
    'utm', jsonb_strip_nulls(jsonb_build_object(
      'utm_source',   v_link.utm_source,
      'utm_medium',   v_link.utm_medium,
      'utm_campaign', v_link.utm_campaign,
      'utm_content',  v_link.utm_content,
      'utm_term',     v_link.utm_term
    ))
  );
END;
$$;


ALTER FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text") IS 'Resolve /r/<code> para destino + UTMs e registra o clique em engagement_events, tudo numa ida. Chamável por anônimo: a rota é pública por definição. Link arquivado ainda resolve — arquivar não pode quebrar peça já distribuída. TP-7 7B.';



CREATE OR REPLACE FUNCTION "public"."safe_to_numeric"("val" "text") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
  IF val IS NULL OR val = '' OR val = 'null' OR val = 'N/A' THEN
    RETURN NULL;
  END IF;
  -- Replace comma with period for decimal separator
  RETURN REPLACE(val, ',', '.')::NUMERIC;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."safe_to_numeric"("val" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text" DEFAULT NULL::"text", "p_partner_id" "uuid" DEFAULT NULL::"uuid", "p_category_name" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_results JSONB;
BEGIN
    SELECT jsonb_agg(row_data) INTO v_results
    FROM (
        SELECT DISTINCT jsonb_build_object(
            'id', kd.id,
            'title', kd.title,
            'storage_path', kd.storage_path,
            'category_name', kc.name,
            'partner_name', p.name
        ) AS row_data
        FROM public.knowledge_documents kd
        LEFT JOIN public.knowledge_categories kc ON kd.category_id = kc.id
        LEFT JOIN public.partners p ON kd.partner_id = p.id
        LEFT JOIN public.knowledge_keywords kk ON kk.document_id = kd.id
        WHERE kd.is_active = true
          AND (
              (p_keyword IS NOT NULL AND kk.keyword ILIKE '%' || p_keyword || '%')
              OR (p_partner_id IS NOT NULL AND kd.partner_id = p_partner_id)
              OR (p_category_name IS NOT NULL AND kc.name = p_category_name)
          )
    ) sub;

    RETURN COALESCE(v_results, '[]'::jsonb);
END;
$$;


ALTER FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."campus" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "uuid",
    "external_code" "text",
    "name" "text" NOT NULL,
    "city" "text",
    "state" "text",
    "latitude" double precision,
    "longitude" double precision,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "region" "text"
);


ALTER TABLE "public"."campus" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."courses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "campus_id" "uuid",
    "course_code" "text",
    "course_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "degree_type" "text"
);


ALTER TABLE "public"."courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."institutions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "external_code" "text",
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_partner" boolean DEFAULT false
);


ALTER TABLE "public"."institutions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."institutions_info_emec" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "uuid",
    "maintainer_code" "text",
    "maintainer_name" "text",
    "cnpj" "text",
    "legal_nature" "text",
    "phone" "text",
    "site" "text",
    "email" "text",
    "address_seat" "text",
    "city" "text",
    "state" "text",
    "academic_organization" "text",
    "credentialing_type" "text",
    "administrative_category" "text",
    "creation_date" "date",
    "ci" "text",
    "ci_year" "text",
    "ci_ead" "text",
    "ci_ead_year" "text",
    "igc" "text",
    "igc_year" "text",
    "rector" "text",
    "legal_representative" "text",
    "current_signs" "text",
    "status" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."institutions_info_emec" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."institutions_info_sisu" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "uuid",
    "acronym" "text",
    "academic_organization" "text",
    "administrative_category" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."institutions_info_sisu" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."opportunities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "course_id" "uuid",
    "semester" "text",
    "shift" "text",
    "scholarship_type" "text",
    "concurrency_type" "text",
    "year" integer,
    "opportunity_type" "text" DEFAULT 'prouni'::"text",
    "cutoff_score" numeric,
    "raw_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_nubo_pick" boolean DEFAULT false,
    "concurrency_tags" "jsonb",
    "scholarship_tags" "jsonb"
);


ALTER TABLE "public"."opportunities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."opportunities_prouni_vacancies" (
    "opportunity_id" "uuid" NOT NULL,
    "bolsas_ampla_ofertada" integer DEFAULT 0,
    "bolsas_cota_ofertada" integer DEFAULT 0,
    "bolsas_ampla_ocupada" integer DEFAULT 0,
    "bolsas_cota_ocupada" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."opportunities_prouni_vacancies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."opportunities_sisu_vacancies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "opportunity_id" "uuid",
    "qt_semestre" "text",
    "nu_vagas_autorizadas" "text",
    "qt_vagas_ofertadas" "text",
    "qt_vagas_ofertadas_prev" "text",
    "nu_percentual_bonus" "text",
    "tp_mod_concorrencia" "text",
    "tp_cota" "text",
    "ds_mod_concorrencia" "text",
    "perc_uf_ibge_ppi" "text",
    "perc_uf_ibge_pp" "text",
    "perc_uf_ibge_i" "text",
    "perc_uf_ibge_q" "text",
    "perc_uf_ibge_pcd" "text",
    "nu_perc_lei" "text",
    "nu_perc_ppi" "text",
    "nu_perc_pp" "text",
    "nu_perc_i" "text",
    "nu_perc_q" "text",
    "nu_perc_pcd" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "peso_redacao" numeric,
    "peso_linguagens" numeric,
    "peso_matematica" numeric,
    "peso_ciencias_humanas" numeric,
    "peso_ciencias_natureza" numeric,
    "nota_minima_redacao" numeric,
    "nota_minima_linguagens" numeric,
    "nota_minima_matematica" numeric,
    "nota_minima_ciencias_humanas" numeric,
    "nota_minima_ciencias_natureza" numeric,
    "nu_media_minima_enem" numeric,
    "qt_inscricao" "text"
);


ALTER TABLE "public"."opportunities_sisu_vacancies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partner_institutions" (
    "institution_id" "uuid" NOT NULL,
    "logo_url" "text",
    "cover_url" "text",
    "description" "text",
    "brand_color" "text",
    "location" "text",
    "website_url" "text"
);


ALTER TABLE "public"."partner_institutions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."partner_institutions"."location" IS 'Display location for the partner (e.g. "Nacional", "São Paulo")';



COMMENT ON COLUMN "public"."partner_institutions"."website_url" IS 'URL of the partner institution website.';



CREATE TABLE IF NOT EXISTS "public"."partner_opportunities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "opportunity_type" character varying NOT NULL,
    "eligibility_criteria" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "external_redirect_config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" character varying DEFAULT 'inactive'::character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "category" "text",
    CONSTRAINT "partner_opportunities_opportunity_type_check" CHECK ((("opportunity_type")::"text" = ANY ((ARRAY['programa de bolsa'::character varying, 'programa educacional'::character varying])::"text"[]))),
    CONSTRAINT "partner_opportunities_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['inactive'::character varying, 'incoming'::character varying, 'opened'::character varying, 'closed'::character varying])::"text"[])))
);


ALTER TABLE "public"."partner_opportunities" OWNER TO "postgres";


COMMENT ON COLUMN "public"."partner_opportunities"."starts_at" IS 'Inicio do periodo de inscricoes da oportunidade parceira';



COMMENT ON COLUMN "public"."partner_opportunities"."ends_at" IS 'Fim do periodo de inscricoes da oportunidade parceira';



CREATE TABLE IF NOT EXISTS "public"."programs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "type" "text" NOT NULL,
    "cycle_year" integer NOT NULL,
    "cycle_semester" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'incoming'::"text" NOT NULL,
    "redirect_url" "text",
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "prev_program_id" "uuid",
    "is_fully_imported" boolean DEFAULT false,
    CONSTRAINT "programs_cycle_semester_check" CHECK (("cycle_semester" = ANY (ARRAY['1'::"text", '2'::"text"]))),
    CONSTRAINT "programs_status_check" CHECK (("status" = ANY (ARRAY['incoming'::"text", 'opened'::"text", 'closed'::"text", 'inactive'::"text"]))),
    CONSTRAINT "programs_type_check" CHECK (("type" = ANY (ARRAY['sisu'::"text", 'prouni'::"text"])))
);


ALTER TABLE "public"."programs" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."v_unified_opportunities" AS
 SELECT "sisu_branch"."unified_id",
    "sisu_branch"."title",
    "sisu_branch"."provider_name",
    "sisu_branch"."type",
    "sisu_branch"."opportunity_type",
    "sisu_branch"."category",
    "sisu_branch"."is_partner",
    "sisu_branch"."location",
    "sisu_branch"."badges",
    "sisu_branch"."created_at",
    "sisu_branch"."external_redirect_url",
    "sisu_branch"."external_redirect_enabled",
    "sisu_branch"."status",
    "sisu_branch"."starts_at",
    "sisu_branch"."ends_at",
    "sisu_branch"."match_score",
    "sisu_branch"."institution_cover_url",
    "sisu_branch"."nu_vagas_autorizadas",
    "sisu_branch"."institution_id",
    "sisu_branch"."institution_igc",
    "sisu_branch"."institution_organization",
    "sisu_branch"."institution_category",
    "sisu_branch"."institution_site",
    "sisu_branch"."eligibility_criteria",
    "sisu_branch"."benefits",
    "sisu_branch"."brand_color",
    "sisu_branch"."weights",
    "sisu_branch"."institution_acronym",
    "sisu_branch"."latitude",
    "sisu_branch"."longitude",
    "sisu_branch"."min_cutoff_score_current",
    "sisu_branch"."min_cutoff_score_prev",
    "sisu_branch"."max_cutoff_score_current",
    "sisu_branch"."max_cutoff_score_prev",
    "sisu_branch"."qt_vagas_ofertadas_current",
    "sisu_branch"."qt_vagas_ofertadas_prev",
    "sisu_branch"."qt_inscricao_current",
    "sisu_branch"."qt_inscricao_prev",
    "sisu_branch"."nu_media_minima_enem_current",
    "sisu_branch"."nu_media_minima_enem_prev",
    "sisu_branch"."vagas_ociosas_current",
    "sisu_branch"."vagas_ociosas_prev",
    "sisu_branch"."search_text"
   FROM ( SELECT DISTINCT ON ("c"."id") ('mec_'::"text" || ("c"."id")::"text") AS "unified_id",
            "c"."course_name" AS "title",
            "i"."name" AS "provider_name",
            'sisu'::"text" AS "type",
            'sisu'::"text" AS "opportunity_type",
            'public_universities'::"text" AS "category",
            false AS "is_partner",
            (("cp"."city" || ', '::"text") || "cp"."state") AS "location",
            ("jsonb_build_array"("o"."shift") - 'null'::"text") AS "badges",
            "o"."created_at",
            NULL::"text" AS "external_redirect_url",
            false AS "external_redirect_enabled",
            "p"."status",
            "id_dates"."start_date" AS "starts_at",
            "id_dates"."end_date" AS "ends_at",
            NULL::numeric AS "match_score",
            NULL::"text" AS "institution_cover_url",
            "sv_curr"."nu_vagas_autorizadas",
            "i"."id" AS "institution_id",
            "ie"."igc" AS "institution_igc",
            "ie"."academic_organization" AS "institution_organization",
            "ie"."administrative_category" AS "institution_category",
            "ie"."site" AS "institution_site",
            NULL::"jsonb" AS "eligibility_criteria",
            NULL::"jsonb" AS "benefits",
            NULL::"text" AS "brand_color",
            "jsonb_build_object"('redacao', "sv_curr"."peso_redacao", 'matematica', "sv_curr"."peso_matematica", 'linguagens', "sv_curr"."peso_linguagens", 'humanas', "sv_curr"."peso_ciencias_humanas", 'natureza', "sv_curr"."peso_ciencias_natureza") AS "weights",
            "sis"."acronym" AS "institution_acronym",
            "cp"."latitude",
            "cp"."longitude",
            "s_curr"."min_cutoff" AS "min_cutoff_score_current",
            "s_prev"."min_cutoff" AS "min_cutoff_score_prev",
            "s_curr"."max_cutoff" AS "max_cutoff_score_current",
            "s_prev"."max_cutoff" AS "max_cutoff_score_prev",
            "sv_curr"."qt_vagas_ofertadas" AS "qt_vagas_ofertadas_current",
            "sv_prev"."qt_vagas_ofertadas" AS "qt_vagas_ofertadas_prev",
            "sv_curr"."qt_inscricao" AS "qt_inscricao_current",
            "sv_prev_inscricao"."qt_inscricao" AS "qt_inscricao_prev",
            "sv_curr"."nu_media_minima_enem" AS "nu_media_minima_enem_current",
            "sv_prev"."nu_media_minima_enem" AS "nu_media_minima_enem_prev",
            "vc_curr"."has_vagas_ociosas" AS "vagas_ociosas_current",
            "vc_prev"."has_vagas_ociosas" AS "vagas_ociosas_prev",
            "public"."f_unaccent"(((((((((COALESCE("c"."course_name", ''::"text") || ' '::"text") || COALESCE("i"."name", ''::"text")) || ' '::"text") || COALESCE("cp"."city", ''::"text")) || ' '::"text") || COALESCE("cp"."state", ''::"text")) || ' '::"text") || COALESCE("sis"."acronym", ''::"text"))) AS "search_text"
           FROM (((((((((((((("public"."opportunities" "o"
             JOIN "public"."programs" "p" ON ((("p"."type" = 'sisu'::"text") AND ("p"."status" <> 'inactive'::"text"))))
             JOIN "public"."courses" "c" ON (("c"."id" = "o"."course_id")))
             JOIN "public"."campus" "cp" ON (("cp"."id" = "c"."campus_id")))
             JOIN "public"."institutions" "i" ON (("i"."id" = "cp"."institution_id")))
             LEFT JOIN LATERAL ( SELECT "min"("opp"."cutoff_score") AS "min_cutoff",
                    "max"("opp"."cutoff_score") AS "max_cutoff"
                   FROM "public"."opportunities" "opp"
                  WHERE (("opp"."opportunity_type" = 'sisu'::"text") AND ("opp"."course_id" = "o"."course_id") AND ("opp"."year" = "p"."cycle_year"))) "s_curr" ON (true))
             LEFT JOIN LATERAL ( SELECT "min"("opp"."cutoff_score") AS "min_cutoff",
                    "max"("opp"."cutoff_score") AS "max_cutoff"
                   FROM "public"."opportunities" "opp"
                  WHERE (("opp"."opportunity_type" = 'sisu'::"text") AND ("opp"."course_id" = "o"."course_id") AND ("opp"."year" = ("p"."cycle_year" - 1)))) "s_prev" ON (true))
             LEFT JOIN LATERAL ( SELECT "d"."start_date",
                    "d"."end_date"
                   FROM "public"."important_dates" "d"
                  WHERE (("d"."type" = 'sisu'::"text") AND ("d"."controls_opportunity_dates" = true))
                  ORDER BY "d"."start_date" DESC
                 LIMIT 1) "id_dates" ON (true))
             LEFT JOIN LATERAL ( SELECT "sv"."id",
                    "sv"."opportunity_id",
                    "sv"."qt_semestre",
                    "sv"."nu_vagas_autorizadas",
                    "sv"."qt_vagas_ofertadas",
                    "sv"."qt_vagas_ofertadas_prev",
                    "sv"."nu_percentual_bonus",
                    "sv"."tp_mod_concorrencia",
                    "sv"."tp_cota",
                    "sv"."ds_mod_concorrencia",
                    "sv"."perc_uf_ibge_ppi",
                    "sv"."perc_uf_ibge_pp",
                    "sv"."perc_uf_ibge_i",
                    "sv"."perc_uf_ibge_q",
                    "sv"."perc_uf_ibge_pcd",
                    "sv"."nu_perc_lei",
                    "sv"."nu_perc_ppi",
                    "sv"."nu_perc_pp",
                    "sv"."nu_perc_i",
                    "sv"."nu_perc_q",
                    "sv"."nu_perc_pcd",
                    "sv"."created_at",
                    "sv"."updated_at",
                    "sv"."peso_redacao",
                    "sv"."peso_linguagens",
                    "sv"."peso_matematica",
                    "sv"."peso_ciencias_humanas",
                    "sv"."peso_ciencias_natureza",
                    "sv"."nota_minima_redacao",
                    "sv"."nota_minima_linguagens",
                    "sv"."nota_minima_matematica",
                    "sv"."nota_minima_ciencias_humanas",
                    "sv"."nota_minima_ciencias_natureza",
                    "sv"."nu_media_minima_enem",
                    "sv"."qt_inscricao"
                   FROM ("public"."opportunities_sisu_vacancies" "sv"
                     JOIN "public"."opportunities" "op" ON (("op"."id" = "sv"."opportunity_id")))
                  WHERE (("op"."course_id" = "o"."course_id") AND ("op"."year" = "p"."cycle_year") AND ("op"."opportunity_type" = 'sisu'::"text"))
                 LIMIT 1) "sv_curr" ON (true))
             LEFT JOIN LATERAL ( SELECT "sv"."qt_vagas_ofertadas",
                    "sv"."nu_media_minima_enem"
                   FROM ("public"."opportunities_sisu_vacancies" "sv"
                     JOIN "public"."opportunities" "op" ON (("op"."id" = "sv"."opportunity_id")))
                  WHERE (("op"."course_id" = "o"."course_id") AND ("op"."year" = ("p"."cycle_year" - 1)) AND ("op"."opportunity_type" = 'sisu'::"text"))
                 LIMIT 1) "sv_prev" ON (true))
             LEFT JOIN LATERAL ( SELECT "sv"."qt_inscricao"
                   FROM ("public"."opportunities_sisu_vacancies" "sv"
                     JOIN "public"."opportunities" "op" ON (("op"."id" = "sv"."opportunity_id")))
                  WHERE (("op"."course_id" = "o"."course_id") AND ("op"."year" = ("p"."cycle_year" - 1)) AND ("op"."opportunity_type" = 'sisu'::"text") AND ("sv"."qt_inscricao" IS NOT NULL))
                  ORDER BY ("sv"."qt_inscricao")::integer DESC
                 LIMIT 1) "sv_prev_inscricao" ON (true))
             LEFT JOIN LATERAL ( SELECT
                        CASE
                            WHEN ("count"("sv"."qt_inscricao") = 0) THEN NULL::boolean
                            ELSE "bool_or"((("replace"("sv"."qt_vagas_ofertadas", '.'::"text", ''::"text"))::integer > ("sv"."qt_inscricao")::integer))
                        END AS "has_vagas_ociosas"
                   FROM ("public"."opportunities_sisu_vacancies" "sv"
                     JOIN "public"."opportunities" "op" ON (("op"."id" = "sv"."opportunity_id")))
                  WHERE (("op"."course_id" = "o"."course_id") AND ("op"."opportunity_type" = 'sisu'::"text") AND ("op"."year" = "p"."cycle_year") AND ("sv"."qt_inscricao" IS NOT NULL) AND ("sv"."qt_vagas_ofertadas" IS NOT NULL))) "vc_curr" ON (true))
             LEFT JOIN LATERAL ( SELECT
                        CASE
                            WHEN ("count"("sv"."qt_inscricao") = 0) THEN NULL::boolean
                            ELSE "bool_or"((("replace"("sv"."qt_vagas_ofertadas", '.'::"text", ''::"text"))::integer > ("sv"."qt_inscricao")::integer))
                        END AS "has_vagas_ociosas"
                   FROM ("public"."opportunities_sisu_vacancies" "sv"
                     JOIN "public"."opportunities" "op" ON (("op"."id" = "sv"."opportunity_id")))
                  WHERE (("op"."course_id" = "o"."course_id") AND ("op"."opportunity_type" = 'sisu'::"text") AND ("op"."year" = ("p"."cycle_year" - 1)) AND ("sv"."qt_inscricao" IS NOT NULL) AND ("sv"."qt_vagas_ofertadas" IS NOT NULL))) "vc_prev" ON (true))
             LEFT JOIN "public"."institutions_info_emec" "ie" ON (("ie"."institution_id" = "i"."id")))
             LEFT JOIN "public"."institutions_info_sisu" "sis" ON (("sis"."institution_id" = "i"."id")))
          WHERE (("o"."opportunity_type" = 'sisu'::"text") AND ("o"."year" = "p"."cycle_year") AND ("o"."semester" = "p"."cycle_semester"))
          ORDER BY "c"."id", "o"."created_at") "sisu_branch"
UNION ALL
 SELECT "prouni_branch"."unified_id",
    "prouni_branch"."title",
    "prouni_branch"."provider_name",
    "prouni_branch"."type",
    "prouni_branch"."opportunity_type",
    "prouni_branch"."category",
    "prouni_branch"."is_partner",
    "prouni_branch"."location",
    "prouni_branch"."badges",
    "prouni_branch"."created_at",
    "prouni_branch"."external_redirect_url",
    "prouni_branch"."external_redirect_enabled",
    "prouni_branch"."status",
    "prouni_branch"."starts_at",
    "prouni_branch"."ends_at",
    "prouni_branch"."match_score",
    "prouni_branch"."institution_cover_url",
    "prouni_branch"."nu_vagas_autorizadas",
    "prouni_branch"."institution_id",
    "prouni_branch"."institution_igc",
    "prouni_branch"."institution_organization",
    "prouni_branch"."institution_category",
    "prouni_branch"."institution_site",
    "prouni_branch"."eligibility_criteria",
    "prouni_branch"."benefits",
    "prouni_branch"."brand_color",
    "prouni_branch"."weights",
    "prouni_branch"."institution_acronym",
    "prouni_branch"."latitude",
    "prouni_branch"."longitude",
    "prouni_branch"."min_cutoff_score_current",
    "prouni_branch"."min_cutoff_score_prev",
    "prouni_branch"."max_cutoff_score_current",
    "prouni_branch"."max_cutoff_score_prev",
    "prouni_branch"."qt_vagas_ofertadas_current",
    "prouni_branch"."qt_vagas_ofertadas_prev",
    "prouni_branch"."qt_inscricao_current",
    "prouni_branch"."qt_inscricao_prev",
    "prouni_branch"."nu_media_minima_enem_current",
    "prouni_branch"."nu_media_minima_enem_prev",
    "prouni_branch"."vagas_ociosas_current",
    "prouni_branch"."vagas_ociosas_prev",
    "prouni_branch"."search_text"
   FROM ( SELECT DISTINCT ON ("c"."id") ('mec_'::"text" || ("c"."id")::"text") AS "unified_id",
            "c"."course_name" AS "title",
            "i"."name" AS "provider_name",
            'prouni'::"text" AS "type",
            'prouni'::"text" AS "opportunity_type",
            'grants_scholarships'::"text" AS "category",
            false AS "is_partner",
            (("cp"."city" || ', '::"text") || "cp"."state") AS "location",
            ("jsonb_build_array"('100% Gratuito', "o"."shift") - 'null'::"text") AS "badges",
            "o"."created_at",
            NULL::"text" AS "external_redirect_url",
            false AS "external_redirect_enabled",
            "p"."status",
            "id_dates"."start_date" AS "starts_at",
            "id_dates"."end_date" AS "ends_at",
            NULL::numeric AS "match_score",
            NULL::"text" AS "institution_cover_url",
            NULL::"text" AS "nu_vagas_autorizadas",
            "i"."id" AS "institution_id",
            "ie"."igc" AS "institution_igc",
            "ie"."academic_organization" AS "institution_organization",
            "ie"."administrative_category" AS "institution_category",
            "ie"."site" AS "institution_site",
            NULL::"jsonb" AS "eligibility_criteria",
            NULL::"jsonb" AS "benefits",
            NULL::"text" AS "brand_color",
            NULL::"jsonb" AS "weights",
            "sis"."acronym" AS "institution_acronym",
            "cp"."latitude",
            "cp"."longitude",
            "s_curr"."min_cutoff" AS "min_cutoff_score_current",
            "s_prev"."min_cutoff" AS "min_cutoff_score_prev",
            "s_curr"."max_cutoff" AS "max_cutoff_score_current",
            "s_prev"."max_cutoff" AS "max_cutoff_score_prev",
            "pv_curr"."qt_vagas_ofertadas" AS "qt_vagas_ofertadas_current",
            "pv_prev"."qt_vagas_ofertadas" AS "qt_vagas_ofertadas_prev",
            NULL::"text" AS "qt_inscricao_current",
            NULL::"text" AS "qt_inscricao_prev",
            NULL::numeric AS "nu_media_minima_enem_current",
            NULL::numeric AS "nu_media_minima_enem_prev",
            (COALESCE("pv_curr"."vagas_ociosas", (0)::bigint) > 0) AS "vagas_ociosas_current",
            (COALESCE("pv_prev"."vagas_ociosas", (0)::bigint) > 0) AS "vagas_ociosas_prev",
            "public"."f_unaccent"(((((((COALESCE("c"."course_name", ''::"text") || ' '::"text") || COALESCE("i"."name", ''::"text")) || ' '::"text") || COALESCE("cp"."city", ''::"text")) || ' '::"text") || COALESCE("sis"."acronym", ''::"text"))) AS "search_text"
           FROM ((((((((((("public"."opportunities" "o"
             JOIN "public"."programs" "p" ON ((("p"."type" = 'prouni'::"text") AND ("p"."status" <> 'inactive'::"text"))))
             JOIN "public"."courses" "c" ON (("c"."id" = "o"."course_id")))
             JOIN "public"."campus" "cp" ON (("cp"."id" = "c"."campus_id")))
             JOIN "public"."institutions" "i" ON (("i"."id" = "cp"."institution_id")))
             LEFT JOIN LATERAL ( SELECT "min"("opp"."cutoff_score") AS "min_cutoff",
                    "max"("opp"."cutoff_score") AS "max_cutoff"
                   FROM "public"."opportunities" "opp"
                  WHERE (("opp"."opportunity_type" = 'prouni'::"text") AND ("opp"."course_id" = "o"."course_id") AND ("opp"."year" = "p"."cycle_year"))) "s_curr" ON (true))
             LEFT JOIN LATERAL ( SELECT "min"("opp"."cutoff_score") AS "min_cutoff",
                    "max"("opp"."cutoff_score") AS "max_cutoff"
                   FROM "public"."opportunities" "opp"
                  WHERE (("opp"."opportunity_type" = 'prouni'::"text") AND ("opp"."course_id" = "o"."course_id") AND ("opp"."year" = ("p"."cycle_year" - 1)))) "s_prev" ON (true))
             LEFT JOIN LATERAL ( SELECT "d"."start_date",
                    "d"."end_date"
                   FROM "public"."important_dates" "d"
                  WHERE (("d"."type" = 'prouni'::"text") AND ("d"."controls_opportunity_dates" = true))
                  ORDER BY "d"."start_date" DESC
                 LIMIT 1) "id_dates" ON (true))
             LEFT JOIN LATERAL ( SELECT ("sum"(("pv"."bolsas_ampla_ofertada" + "pv"."bolsas_cota_ofertada")))::"text" AS "qt_vagas_ofertadas",
                    "sum"((("pv"."bolsas_ampla_ofertada" + "pv"."bolsas_cota_ofertada") - ("pv"."bolsas_ampla_ocupada" + "pv"."bolsas_cota_ocupada"))) AS "vagas_ociosas"
                   FROM ("public"."opportunities_prouni_vacancies" "pv"
                     JOIN "public"."opportunities" "opp" ON (("opp"."id" = "pv"."opportunity_id")))
                  WHERE (("opp"."course_id" = "o"."course_id") AND ("opp"."year" = "p"."cycle_year") AND ("opp"."opportunity_type" = 'prouni'::"text"))) "pv_curr" ON (true))
             LEFT JOIN LATERAL ( SELECT ("sum"(("pv"."bolsas_ampla_ofertada" + "pv"."bolsas_cota_ofertada")))::"text" AS "qt_vagas_ofertadas",
                    "sum"((("pv"."bolsas_ampla_ofertada" + "pv"."bolsas_cota_ofertada") - ("pv"."bolsas_ampla_ocupada" + "pv"."bolsas_cota_ocupada"))) AS "vagas_ociosas"
                   FROM ("public"."opportunities_prouni_vacancies" "pv"
                     JOIN "public"."opportunities" "opp" ON (("opp"."id" = "pv"."opportunity_id")))
                  WHERE (("opp"."course_id" = "o"."course_id") AND ("opp"."year" = ("p"."cycle_year" - 1)) AND ("opp"."opportunity_type" = 'prouni'::"text"))) "pv_prev" ON (true))
             LEFT JOIN "public"."institutions_info_emec" "ie" ON (("ie"."institution_id" = "i"."id")))
             LEFT JOIN "public"."institutions_info_sisu" "sis" ON (("sis"."institution_id" = "i"."id")))
          WHERE (("o"."opportunity_type" = 'prouni'::"text") AND ("o"."year" = "p"."cycle_year") AND ("o"."semester" = "p"."cycle_semester"))
          ORDER BY "c"."id", "o"."created_at") "prouni_branch"
UNION ALL
 SELECT ('partner_'::"text" || ("po"."id")::"text") AS "unified_id",
    "po"."name" AS "title",
    "i"."name" AS "provider_name",
    'partner'::"text" AS "type",
    "po"."opportunity_type",
    COALESCE("po"."category", 'educational_programs'::"text") AS "category",
    true AS "is_partner",
    'Nacional'::"text" AS "location",
    COALESCE(("po"."eligibility_criteria" -> 'badges'::"text"), '[]'::"jsonb") AS "badges",
    "po"."created_at",
    ("po"."external_redirect_config" ->> 'url'::"text") AS "external_redirect_url",
    COALESCE((("po"."external_redirect_config" ->> 'enabled'::"text"))::boolean, false) AS "external_redirect_enabled",
    ("po"."status")::"text" AS "status",
    "po"."starts_at",
    "po"."ends_at",
    NULL::numeric AS "match_score",
    "pi"."cover_url" AS "institution_cover_url",
    NULL::"text" AS "nu_vagas_autorizadas",
    "i"."id" AS "institution_id",
    "ie"."igc" AS "institution_igc",
    "ie"."academic_organization" AS "institution_organization",
    "ie"."administrative_category" AS "institution_category",
    "ie"."site" AS "institution_site",
    "po"."eligibility_criteria",
    NULL::"jsonb" AS "benefits",
    "pi"."brand_color",
    NULL::"jsonb" AS "weights",
    "sis"."acronym" AS "institution_acronym",
    NULL::double precision AS "latitude",
    NULL::double precision AS "longitude",
    NULL::numeric AS "min_cutoff_score_current",
    NULL::numeric AS "min_cutoff_score_prev",
    NULL::numeric AS "max_cutoff_score_current",
    NULL::numeric AS "max_cutoff_score_prev",
    NULL::"text" AS "qt_vagas_ofertadas_current",
    NULL::"text" AS "qt_vagas_ofertadas_prev",
    NULL::"text" AS "qt_inscricao_current",
    NULL::"text" AS "qt_inscricao_prev",
    NULL::numeric AS "nu_media_minima_enem_current",
    NULL::numeric AS "nu_media_minima_enem_prev",
    NULL::boolean AS "vagas_ociosas_current",
    NULL::boolean AS "vagas_ociosas_prev",
    "public"."f_unaccent"(((((COALESCE("po"."name", ''::"text") || ' '::"text") || COALESCE("i"."name", ''::"text")) || ' '::"text") || COALESCE("sis"."acronym", ''::"text"))) AS "search_text"
   FROM (((("public"."partner_opportunities" "po"
     JOIN "public"."institutions" "i" ON (("i"."id" = "po"."institution_id")))
     LEFT JOIN "public"."partner_institutions" "pi" ON (("pi"."institution_id" = "i"."id")))
     LEFT JOIN "public"."institutions_info_emec" "ie" ON (("ie"."institution_id" = "i"."id")))
     LEFT JOIN "public"."institutions_info_sisu" "sis" ON (("sis"."institution_id" = "i"."id")))
  WHERE (("po"."status")::"text" = ANY ((ARRAY['incoming'::character varying, 'opened'::character varying, 'closed'::character varying])::"text"[]))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."v_unified_opportunities" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_opportunities"("p_q" "text") RETURNS SETOF "public"."v_unified_opportunities"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT *
  FROM public.v_unified_opportunities
  WHERE search_text LIKE '%' || public.f_unaccent(p_q) || '%';
$$;


ALTER FUNCTION "public"."search_opportunities"("p_q" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_opportunities_by_distance"("p_lat" double precision, "p_long" double precision, "p_q" "text") RETURNS TABLE("unified_id" "text", "title" "text", "provider_name" "text", "type" "text", "opportunity_type" "text", "category" "text", "is_partner" boolean, "location" "text", "badges" "jsonb", "created_at" timestamp with time zone, "external_redirect_url" "text", "external_redirect_enabled" boolean, "status" "text", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "match_score" numeric, "institution_cover_url" "text", "nu_vagas_autorizadas" "text", "institution_id" "uuid", "institution_igc" "text", "institution_organization" "text", "institution_category" "text", "institution_site" "text", "eligibility_criteria" "jsonb", "benefits" "jsonb", "brand_color" "text", "weights" "jsonb", "institution_acronym" "text", "latitude" double precision, "longitude" double precision, "min_cutoff_score_current" numeric, "min_cutoff_score_prev" numeric, "max_cutoff_score_current" numeric, "max_cutoff_score_prev" numeric, "qt_vagas_ofertadas_current" "text", "qt_vagas_ofertadas_prev" "text", "qt_inscricao_current" "text", "qt_inscricao_prev" "text", "nu_media_minima_enem_current" numeric, "nu_media_minima_enem_prev" numeric, "vagas_ociosas_current" boolean, "vagas_ociosas_prev" boolean, "search_text" "text", "distance_km" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    v.*,
    CASE
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL
           AND p_lat IS NOT NULL AND p_long IS NOT NULL THEN
        6371.0 * acos(
          LEAST(1.0, GREATEST(-1.0,
            cos(radians(p_lat)) * cos(radians(v.latitude)) *
            cos(radians(v.longitude) - radians(p_long)) +
            sin(radians(p_lat)) * sin(radians(v.latitude))
          ))
        )
      ELSE NULL
    END AS distance_km
  FROM public.v_unified_opportunities v
  WHERE v.search_text LIKE '%' || public.f_unaccent(p_q) || '%';
$$;


ALTER FUNCTION "public"."search_opportunities_by_distance"("p_lat" double precision, "p_long" double precision, "p_q" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_partner_role_and_link"("p_user_id" "uuid", "p_partner_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
     RAISE EXCEPTION 'Not authenticated';
  END IF;

  UPDATE auth.users
  SET role = 'partner'
  WHERE id = p_user_id;

  INSERT INTO public.partners_users (user_id, partner_id)
  VALUES (p_user_id, p_partner_id)
  ON CONFLICT (user_id, partner_id) DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."set_partner_role_and_link"("p_user_id" "uuid", "p_partner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."snapshot_agent_prompt_version"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.system_instruction IS DISTINCT FROM OLD.system_instruction
       OR NEW.model IS DISTINCT FROM OLD.model
       OR NEW.max_steps IS DISTINCT FROM OLD.max_steps
       OR NEW.temperature IS DISTINCT FROM OLD.temperature THEN
        INSERT INTO agent_prompt_versions (
            agent_prompt_id, agent_key, system_instruction, model, max_steps, temperature, created_at
        ) VALUES (
            OLD.id, OLD.agent_key, OLD.system_instruction, OLD.model, OLD.max_steps, OLD.temperature,
            COALESCE(OLD.updated_at, now())
        );
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."snapshot_agent_prompt_version"() OWNER TO "postgres";


CREATE PROCEDURE "public"."standardize_user_locations"()
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    -- Logic from 85_standardize_user_profiles_location.sql
    -- A. Extract State "City - UF"
    UPDATE public.user_profiles up
    SET state = UPPER((regexp_matches(city, '(.+?)\s*[-\/]\s*([a-zA-Z]{2})\s*$', 'i'))[2]),
        city = TRIM((regexp_matches(city, '(.+?)\s*[-\/]\s*([a-zA-Z]{2})\s*$', 'i'))[1])
    WHERE (state IS NULL OR state = '') AND city ~* '(.+?)\s*[-\/]\s*([a-zA-Z]{2})\s*$';

    -- B. Match State Names
    UPDATE public.user_profiles up
    SET state = s.uf, city = NULL
    FROM public.states s 
    WHERE (up.state IS NULL OR up.state = '') AND (LOWER(TRIM(up.city)) = LOWER(s.name) OR LOWER(f_unaccent(TRIM(up.city))) = LOWER(f_unaccent(s.name)));
END;
$_$;


ALTER PROCEDURE "public"."standardize_user_locations"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_application_v1"("p_application_id" "uuid", "p_answers" "jsonb", "p_final_status" "text" DEFAULT 'SUBMITTED'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_caller  UUID := auth.uid();
BEGIN
  -- Validate final status
  IF p_final_status NOT IN ('SUBMITTED', 'redirected', 'pending') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid final status');
  END IF;

  SELECT user_id INTO v_user_id
  FROM student_applications
  WHERE id = p_application_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Application not found');
  END IF;

  IF v_user_id <> v_caller THEN
    IF NOT EXISTS (
      SELECT 1 FROM user_profiles
      WHERE id = v_user_id AND parent_user_id = v_caller
    ) THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unauthorized');
    END IF;
  END IF;

  UPDATE student_applications
  SET
    answers    = COALESCE(answers, '{}'::jsonb) || p_answers,
    status     = p_final_status,
    updated_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('success', true, 'application_id', p_application_id);
END;
$$;


ALTER FUNCTION "public"."submit_application_v1"("p_application_id" "uuid", "p_answers" "jsonb", "p_final_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_goals" "text" DEFAULT NULL::"text", "p_ip" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  -- Linha de base real: 5 solicitações em 6 meses (fev a mai/2026). Os limites
  -- abaixo são ordens de grandeza acima do uso legítimo — só disparam em abuso.
  c_max_per_ip_hour    CONSTANT INT := 5;
  c_max_global_hour    CONSTANT INT := 60;
  c_dedupe_hours       CONSTANT INT := 24;
  c_attempt_retention  CONSTANT INT := 24;
  -- Sal fixo no corpo da função: só roles privilegiados leem a definição, e o
  -- hash serve para contar, não para autenticar.
  c_salt               CONSTANT TEXT := 'nubo-partner-throttle-v1';

  v_institution TEXT;
  v_contact     TEXT;
  v_how         TEXT;
  v_goals       TEXT;
  v_email       TEXT;
  v_whatsapp    TEXT;
  v_digits      TEXT;
  v_has_email   BOOLEAN;
  v_has_phone   BOOLEAN;
  v_ip_hash     TEXT;
  v_recent_ip   INT;
  v_recent_all  INT;
  v_duplicate   BOOLEAN;
BEGIN
  v_institution := nullif(btrim(coalesce(p_institution_name, '')), '');
  v_contact     := nullif(btrim(coalesce(p_contact_name, '')), '');
  v_how         := nullif(btrim(coalesce(p_how_did_you_know, '')), '');
  v_goals       := nullif(btrim(coalesce(p_goals, '')), '');
  v_email       := lower(nullif(btrim(coalesce(p_email, '')), ''));
  v_whatsapp    := nullif(btrim(coalesce(p_whatsapp, '')), '');
  v_digits      := regexp_replace(coalesce(v_whatsapp, ''), '\D', '', 'g');

  -- Tetos de tamanho: a tabela é texto livre; sem teto, um POST enche o banco.
  v_institution := left(v_institution, 200);
  v_contact     := left(v_contact, 150);
  v_how         := left(v_how, 500);
  v_goals       := left(v_goals, 2000);
  v_email       := left(v_email, 254);
  v_whatsapp    := left(v_whatsapp, 20);

  v_has_email := v_email IS NOT NULL AND v_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$';
  v_has_phone := length(v_digits) >= 10;

  IF v_institution IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'institution_name');
  END IF;
  IF v_contact IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'contact_name');
  END IF;
  IF v_how IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'how_did_you_know');
  END IF;
  IF NOT v_has_email AND NOT v_has_phone THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'contact');
  END IF;

  -- ── Rate limit ─────────────────────────────────────────────────────────────
  v_ip_hash := md5(coalesce(p_ip, 'unknown') || c_salt);

  DELETE FROM public.partner_solicitation_attempts
   WHERE created_at < now() - make_interval(hours => c_attempt_retention);

  SELECT count(*) INTO v_recent_ip
    FROM public.partner_solicitation_attempts
   WHERE ip_hash = v_ip_hash
     AND created_at > now() - interval '1 hour';

  IF v_recent_ip >= c_max_per_ip_hour THEN
    RETURN jsonb_build_object('status', 'rate_limited', 'scope', 'ip');
  END IF;

  SELECT count(*) INTO v_recent_all
    FROM public.partner_solicitation_attempts
   WHERE created_at > now() - interval '1 hour';

  -- Disjuntor contra abuso distribuído, onde o limite por IP não pega.
  IF v_recent_all >= c_max_global_hour THEN
    RETURN jsonb_build_object('status', 'rate_limited', 'scope', 'global');
  END IF;

  -- Registrado ANTES da dedupe: reenvio do mesmo payload também consome o
  -- orçamento, senão um bot repetindo a mesma submissão fica ilimitado.
  INSERT INTO public.partner_solicitation_attempts (ip_hash) VALUES (v_ip_hash);

  -- ── Deduplicação ───────────────────────────────────────────────────────────
  -- Funciona aqui porque a função é SECURITY DEFINER: enxerga as linhas que a
  -- policy de leitura esconderia de um visitante anônimo.
  SELECT EXISTS (
    SELECT 1 FROM public.partner_solicitations s
     WHERE s.institution_name = v_institution
       AND s.created_at > now() - make_interval(hours => c_dedupe_hours)
       AND (
         (v_has_email AND lower(s.email) = v_email)
         OR (v_has_phone AND regexp_replace(coalesce(s.whatsapp, ''), '\D', '', 'g') = v_digits)
       )
  ) INTO v_duplicate;

  IF v_duplicate THEN
    -- Sucesso do ponto de vista de quem preencheu: preencheu uma vez e deu
    -- certo. O que não pode é o comercial receber o mesmo lead três vezes.
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  INSERT INTO public.partner_solicitations (
    institution_name, contact_name, whatsapp, email, how_did_you_know, goals
  ) VALUES (
    v_institution, v_contact, v_whatsapp, v_email, v_how, v_goals
  );

  RETURN jsonb_build_object('status', 'created');
END;
$_$;


ALTER FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text", "p_email" "text", "p_goals" "text", "p_ip" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text", "p_email" "text", "p_goals" "text", "p_ip" "text") IS 'Única porta de entrada para leads de parceria. SECURITY DEFINER para conseguir deduplicar (a policy de leitura é restrita a admin) e para aplicar rate limit por hash de IP usando o próprio banco como estado compartilhado. Devolve apenas status: created | duplicate | rate_limited | invalid. TP-5 5b / card 7410a5bc.';



CREATE OR REPLACE FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
  DECLARE
    v_user_id UUID;
  BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
      RAISE EXCEPTION 'Not authenticated';
    END IF;

    IF p_type = 'course' THEN
      IF EXISTS (SELECT 1 FROM public.user_favorites WHERE user_id = v_user_id AND course_id = p_id) THEN
        DELETE FROM public.user_favorites WHERE user_id = v_user_id AND course_id = p_id;
      ELSE
        INSERT INTO public.user_favorites (user_id, course_id) VALUES (v_user_id, p_id);
      END IF;
    ELSIF p_type = 'partner' THEN
      IF EXISTS (SELECT 1 FROM public.user_favorites WHERE user_id = v_user_id AND partner_opportunities_id = p_id) THEN
        DELETE FROM public.user_favorites WHERE user_id = v_user_id AND partner_opportunities_id = p_id;
      ELSE
        INSERT INTO public.user_favorites (user_id, partner_opportunities_id) VALUES (v_user_id, p_id);
      END IF;
    ELSIF p_type = 'institution' THEN
      IF EXISTS (SELECT 1 FROM public.user_favorites WHERE user_id = v_user_id AND institution_id = p_id) THEN
        DELETE FROM public.user_favorites WHERE user_id = v_user_id AND institution_id = p_id;
      ELSE
        INSERT INTO public.user_favorites (user_id, institution_id) VALUES (v_user_id, p_id);
      END IF;
    ELSE
      RAISE EXCEPTION 'Invalid type. Must be "course", "partner", or "institution".';
    END IF;
  END;
  $$;


ALTER FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_etl_run_logs_timestamps"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id UUID;
  v_email TEXT;
  v_full_name TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.started_at := clock_timestamp();
    v_user_id := auth.uid();
    NEW.user_id := v_user_id;
    
    IF v_user_id IS NOT NULL THEN
      -- Try to get from user_profiles first
      SELECT full_name INTO v_full_name FROM public.user_profiles WHERE id = v_user_id;
      
      -- If not in profiles, try auth.users
      IF v_full_name IS NULL OR v_full_name = '' THEN
        SELECT email, COALESCE(raw_user_meta_data->>'full_name', email) 
        INTO v_email, v_full_name 
        FROM auth.users WHERE id = v_user_id;
      END IF;
      
      NEW.user_name := COALESCE(v_full_name, v_email, 'Usuário Desconhecido');
    ELSE
      NEW.user_name := 'Sistema / Automatizado';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.status IN ('success', 'error') AND (OLD.status = 'running' OR OLD.finished_at IS NULL) THEN
      NEW.finished_at := clock_timestamp();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_etl_run_logs_timestamps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_populate_campus_coordinates"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    IF NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
        SELECT c.latitude, c.longitude
        INTO NEW.latitude, NEW.longitude
        FROM public.cities c
        WHERE c.name = NEW.city AND c.state = NEW.state
        LIMIT 1;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_populate_campus_coordinates"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_update_furthest_passport_phase"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- If the new passport_phase is "further" than the current furthest_passport_phase, update it.
    IF public.get_passport_phase_weight(NEW.passport_phase) > public.get_passport_phase_weight(OLD.furthest_passport_phase) THEN
        NEW.furthest_passport_phase := NEW.passport_phase;
    END IF;
    
    -- Ensure furthest_passport_phase never regresses
    IF public.get_passport_phase_weight(NEW.furthest_passport_phase) < public.get_passport_phase_weight(OLD.furthest_passport_phase) THEN
        NEW.furthest_passport_phase := OLD.furthest_passport_phase;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_update_furthest_passport_phase"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_calculate_passport_eligibility"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Evaluate eligibility for the user who owns this application
    -- Using PERFORM since we don't need to return the JSONB result to the trigger
    PERFORM public.calculate_passport_eligibility(NEW.user_id);
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_calculate_passport_eligibility"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_match_calculation"("p_profile_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_net_id BIGINT;
    v_supabase_url TEXT;
    v_service_key TEXT;
BEGIN
    -- Read from Supabase Vault / app.settings (set via Dashboard > Database > Settings)
    v_supabase_url := current_setting('app.settings.supabase_url', true);
    v_service_key  := current_setting('app.settings.service_role_key', true);

    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE EXCEPTION 'Missing app.settings.supabase_url or app.settings.service_role_key in database configuration';
    END IF;

    -- Mark as starting
    UPDATE public.user_preferences
    SET match_status = 'processing'
    WHERE user_id = p_profile_id;

    -- Call the worker RPC via pg_net (background HTTP POST)
    SELECT net.http_post(
        url := v_supabase_url || '/rest/v1/rpc/calculate_match_async_worker',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_service_key,
            'Content-Type', 'application/json',
            'apikey', v_service_key
        ),
        body := jsonb_build_object('p_profile_id', p_profile_id)
    ) INTO v_net_id;

    RETURN jsonb_build_object('status', 'accepted', 'job_id', v_net_id);
END;
$$;


ALTER FUNCTION "public"."trigger_match_calculation"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_best_enem_score"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_best_avg NUMERIC(6,2) := 0;
    v_year_avg NUMERIC(6,2);
    v_rec RECORD;
BEGIN
    -- Iterate specifically over years 2024 and 2025
    FOR v_rec IN 
        SELECT 
            year,
            COALESCE(nota_linguagens, 0) as l,
            COALESCE(nota_ciencias_humanas, 0) as ch,
            COALESCE(nota_ciencias_natureza, 0) as cn,
            COALESCE(nota_matematica, 0) as m,
            COALESCE(nota_redacao, 0) as r
        FROM public.user_enem_scores 
        WHERE user_id = NEW.user_id 
          AND year IN (2024, 2025) -- Strict filter
        ORDER BY year DESC 
    LOOP
        -- Calculate Simple Average
        v_year_avg := (v_rec.l + v_rec.ch + v_rec.cn + v_rec.m + v_rec.r) / 5.0;
        
        -- Keep the Max
        IF v_year_avg > v_best_avg THEN
            v_best_avg := v_year_avg;
        END IF;
    END LOOP;

    -- Update User Preferences with the calculated best average
    IF v_best_avg > 0 THEN
        UPDATE public.user_preferences 
        SET 
            enem_score = v_best_avg,
            updated_at = now()
        WHERE user_id = NEW.user_id;

        -- Handle case where user_preferences doesn't exist yet (though it should by flow)
        IF NOT FOUND THEN
             INSERT INTO public.user_preferences (id, user_id, enem_score)
             VALUES (gen_random_uuid(), NEW.user_id, v_best_avg);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_best_enem_score"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_own_profile"("p_full_name" "text" DEFAULT NULL::"text", "p_age" integer DEFAULT NULL::integer, "p_city" "text" DEFAULT NULL::"text", "p_education" "text" DEFAULT NULL::"text", "p_zip_code" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_street" "text" DEFAULT NULL::"text", "p_street_number" "text" DEFAULT NULL::"text", "p_complement" "text" DEFAULT NULL::"text", "p_passport_phase" "text" DEFAULT NULL::"text", "p_relationship" "text" DEFAULT NULL::"text", "p_isdependent" boolean DEFAULT NULL::boolean, "p_parent_user_id" "uuid" DEFAULT NULL::"uuid", "p_current_dependent_id" "uuid" DEFAULT NULL::"uuid", "p_target_user_id" "uuid" DEFAULT NULL::"uuid", "p_education_year" "text" DEFAULT NULL::"text", "p_birth_date" "date" DEFAULT NULL::"date", "p_neighborhood" "text" DEFAULT NULL::"text", "p_country" "text" DEFAULT NULL::"text", "p_outside_brazil" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id UUID;
  v_current_profile RECORD;
  v_new_full_name TEXT;
  v_new_age INTEGER;
  v_new_city TEXT;
  v_new_education TEXT;
  v_new_zip_code TEXT;
  v_new_state TEXT;
  v_new_street TEXT;
  v_new_street_number TEXT;
  v_new_complement TEXT;
  v_new_passport_phase TEXT;
  v_new_isdependent BOOLEAN;
  v_new_parent_user_id UUID;
  v_new_current_dependent_id UUID;
  v_new_relationship TEXT;
  v_new_education_year TEXT;
  v_new_birth_date DATE;
  v_new_neighborhood TEXT;
  v_new_country TEXT;
  v_new_outside_brazil BOOLEAN;
  v_is_complete BOOLEAN;
  v_updated_profile JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Determine target user to update
  IF p_target_user_id IS NOT NULL THEN
    v_user_id := p_target_user_id;
    -- Authorization check: you can only update yourself or your dependent
    IF v_user_id != auth.uid() THEN
      IF (SELECT parent_user_id FROM public.user_profiles WHERE id = v_user_id) != auth.uid() THEN
        RAISE EXCEPTION 'Not authorized to update this profile';
      END IF;
    END IF;
  ELSE
    v_user_id := auth.uid();
  END IF;

  SELECT * INTO v_current_profile FROM public.user_profiles WHERE id = v_user_id;

  v_new_full_name := COALESCE(p_full_name, v_current_profile.full_name);
  v_new_age := COALESCE(p_age, v_current_profile.age);
  v_new_city := COALESCE(p_city, v_current_profile.city);
  v_new_education := COALESCE(p_education, v_current_profile.education);
  v_new_zip_code := COALESCE(p_zip_code, v_current_profile.zip_code);
  v_new_state := COALESCE(p_state, v_current_profile.state);
  v_new_street := COALESCE(p_street, v_current_profile.street);
  v_new_street_number := COALESCE(p_street_number, v_current_profile.street_number);
  v_new_complement := COALESCE(p_complement, v_current_profile.complement);
  v_new_passport_phase := COALESCE(p_passport_phase, v_current_profile.passport_phase);
  v_new_isdependent := COALESCE(p_isdependent, v_current_profile.isdependent);
  v_new_parent_user_id := COALESCE(p_parent_user_id, v_current_profile.parent_user_id);
  v_new_current_dependent_id := COALESCE(p_current_dependent_id, v_current_profile.current_dependent_id);
  v_new_relationship := COALESCE(p_relationship, v_current_profile.relationship);
  v_new_education_year := COALESCE(p_education_year, v_current_profile.education_year);
  v_new_birth_date := COALESCE(p_birth_date, v_current_profile.birth_date);
  v_new_neighborhood := COALESCE(p_neighborhood, v_current_profile.neighborhood);
  v_new_country := COALESCE(p_country, v_current_profile.country);
  v_new_outside_brazil := COALESCE(p_outside_brazil, v_current_profile.outside_brazil);

  v_is_complete := (
    v_new_full_name IS NOT NULL AND length(v_new_full_name) > 0
    AND (v_new_age IS NOT NULL OR v_new_birth_date IS NOT NULL)
    AND v_new_city IS NOT NULL AND length(v_new_city) > 0
    AND v_new_education IS NOT NULL AND length(v_new_education) > 0
    AND (
      (v_new_outside_brazil = TRUE AND v_new_country IS NOT NULL AND length(v_new_country) > 0)
      OR
      (COALESCE(v_new_outside_brazil, FALSE) = FALSE AND v_new_zip_code IS NOT NULL AND length(v_new_zip_code) > 0)
    )
    AND (
      (v_new_education NOT IN ('Ensino fundamental', 'Ensino médio incompleto'))
      OR (v_new_education_year IS NOT NULL AND length(v_new_education_year) > 0)
    )
  );

  UPDATE public.user_profiles SET
    full_name = v_new_full_name,
    age = v_new_age,
    city = v_new_city,
    education = v_new_education,
    zip_code = v_new_zip_code,
    state = v_new_state,
    street = v_new_street,
    street_number = v_new_street_number,
    complement = v_new_complement,
    passport_phase = v_new_passport_phase,
    isdependent = v_new_isdependent,
    parent_user_id = v_new_parent_user_id,
    current_dependent_id = v_new_current_dependent_id,
    relationship = v_new_relationship,
    education_year = v_new_education_year,
    birth_date = v_new_birth_date,
    neighborhood = v_new_neighborhood,
    country = v_new_country,
    outside_brazil = v_new_outside_brazil,
    onboarding_completed = CASE WHEN v_is_complete THEN TRUE ELSE onboarding_completed END,
    updated_at = NOW()
  WHERE id = v_user_id
  RETURNING to_jsonb(user_profiles.*) INTO v_updated_profile;

  IF NOT FOUND THEN
    INSERT INTO public.user_profiles (
      id, full_name, age, city, education, education_year,
      zip_code, state, street, street_number, complement,
      passport_phase, isdependent, parent_user_id, current_dependent_id, relationship, onboarding_completed,
      birth_date, neighborhood, country, outside_brazil
    )
    VALUES (
      v_user_id, p_full_name, p_age, p_city, p_education, p_education_year,
      p_zip_code, p_state, p_street, p_street_number, p_complement,
      v_new_passport_phase, p_isdependent, p_parent_user_id, p_current_dependent_id, p_relationship, v_is_complete,
      p_birth_date, p_neighborhood, p_country, p_outside_brazil
    )
    RETURNING to_jsonb(user_profiles.*) INTO v_updated_profile;
  END IF;

  RETURN v_updated_profile;
END;
$$;


ALTER FUNCTION "public"."update_own_profile"("p_full_name" "text", "p_age" integer, "p_city" "text", "p_education" "text", "p_zip_code" "text", "p_state" "text", "p_street" "text", "p_street_number" "text", "p_complement" "text", "p_passport_phase" "text", "p_relationship" "text", "p_isdependent" boolean, "p_parent_user_id" "uuid", "p_current_dependent_id" "uuid", "p_target_user_id" "uuid", "p_education_year" "text", "p_birth_date" "date", "p_neighborhood" "text", "p_country" "text", "p_outside_brazil" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_student_application_answers"("p_application_id" "uuid", "p_answers" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    UPDATE student_applications
    -- Merge the existing answers with the new answers using the || operator
    -- Note: COALESCE handles the case where answers might be NULL initially
    SET 
        answers = COALESCE(answers, '{}'::jsonb) || p_answers,
        updated_at = NOW()
    WHERE id = p_application_id;
END;
$$;


ALTER FUNCTION "public"."update_student_application_answers"("p_application_id" "uuid", "p_answers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
    new.updated_at = now();
    return new;
end;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "alert_type" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "entity_type" "text",
    "entity_id" "text",
    "action_label" "text",
    "action_type" "text",
    "action_metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone,
    CONSTRAINT "admin_alerts_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'critical'::"text"]))),
    CONSTRAINT "admin_alerts_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'acknowledged'::"text", 'resolved'::"text", 'dismissed'::"text"])))
);


ALTER TABLE "public"."admin_alerts" OWNER TO "postgres";


COMMENT ON TABLE "public"."admin_alerts" IS 'Alertas operacionais do Action Center — gerados por Edge Functions de checagem de deadlines';



CREATE TABLE IF NOT EXISTS "public"."agent_errors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "session_id" "uuid",
    "trace_id" "uuid",
    "error_type" "text" NOT NULL,
    "error_message" "text",
    "stack_trace" "text",
    "metadata" "jsonb",
    "recovery_attempted" boolean DEFAULT false,
    "resolved" boolean DEFAULT false,
    "resolved_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agent_errors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_executions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "session_id" "text",
    "workflow" "text",
    "tool_name" "text",
    "tool_input" "jsonb",
    "tool_output" "jsonb",
    "duration_ms" integer,
    "success" boolean,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agent_executions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_feedback" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trace_id" "uuid",
    "user_id" "uuid",
    "session_id" "uuid",
    "feedback_type" "text" NOT NULL,
    "score" double precision,
    "content" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agent_feedback" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_prompt_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_prompt_id" "uuid",
    "agent_key" "text" NOT NULL,
    "system_instruction" "text",
    "model" "text",
    "max_steps" integer,
    "temperature" numeric,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."agent_prompt_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_prompts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_key" "text" NOT NULL,
    "system_instruction" "text" NOT NULL,
    "temperature" numeric(3,2) DEFAULT 0.20,
    "is_active" boolean DEFAULT true,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid",
    "model" "text" DEFAULT 'gemini-2.5-flash'::"text",
    "max_steps" integer DEFAULT 5
);


ALTER TABLE "public"."agent_prompts" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_prompts" IS 'System instructions dinâmicas dos agentes da Cloudinha. Editáveis via Admin /agent-config sem deploy.';



COMMENT ON COLUMN "public"."agent_prompts"."agent_key" IS 'Identificador único do agente: planning, reasoning, response.';



COMMENT ON COLUMN "public"."agent_prompts"."system_instruction" IS 'Prompt de sistema completo injetado no modelo GenAI antes da execução.';



COMMENT ON COLUMN "public"."agent_prompts"."temperature" IS 'Temperatura do modelo GenAI para este agente (0.0 a 2.0).';



COMMENT ON COLUMN "public"."agent_prompts"."model" IS 'Model ID do Google GenAI usado por este agente (ex: gemini-2.5-flash).';



COMMENT ON COLUMN "public"."agent_prompts"."max_steps" IS 'Número máximo de iterações do loop ReAct antes de forçar resposta final.';



CREATE TABLE IF NOT EXISTS "public"."agent_turns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "session_id" "text",
    "total_latency_ms" integer,
    "input_tokens" integer,
    "output_tokens" integer,
    "tools_used" "jsonb",
    "intent_category" "text",
    "action" "text" DEFAULT 'none'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "estimated_cost_usd" numeric(10,6),
    "model_latency_ms" integer,
    "tools_latency_ms" integer,
    "steps" "jsonb" DEFAULT '[]'::"jsonb",
    "agent_output" "text"
);


ALTER TABLE "public"."agent_turns" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_turns" IS 'Telemetria end-to-end de cada turno cognitivo da Cloudinha. Cada linha = 1 ciclo Planning→Reasoning→Response.';



COMMENT ON COLUMN "public"."agent_turns"."estimated_cost_usd" IS 'Custo estimado do turno em USD com base nos tokens consumidos.';



COMMENT ON COLUMN "public"."agent_turns"."model_latency_ms" IS 'Total LLM inference time (all steps combined)';



COMMENT ON COLUMN "public"."agent_turns"."tools_latency_ms" IS 'Total tool execution time (all steps combined)';



COMMENT ON COLUMN "public"."agent_turns"."steps" IS 'Array of ReAct loop steps: [{thought, action: {tool, args}, observation}]';



COMMENT ON COLUMN "public"."agent_turns"."agent_output" IS 'Final unified response text from the ReAct agent';



CREATE TABLE IF NOT EXISTS "public"."ai_insights" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "insights" "jsonb" NOT NULL,
    "data_context" "jsonb" NOT NULL,
    "data_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_insights" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."campaigns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "objective" "text",
    "starts_at" "date",
    "ends_at" "date",
    "owner" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "campaigns_slug_format" CHECK (("slug" ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::"text"))
);


ALTER TABLE "public"."campaigns" OWNER TO "postgres";


COMMENT ON TABLE "public"."campaigns" IS 'Objetivo de negócio agrupador. É tabela e não campo de texto para que agrupar vire JOIN em vez de LIKE ''insper%'' — typo fica impossível e a campanha ganha período, dono e objetivo. TP-7 7B.';



CREATE TABLE IF NOT EXISTS "public"."channel_links" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "campaign_id" "uuid",
    "channel_id" "uuid" NOT NULL,
    "platform_id" "text",
    "code" "text" NOT NULL,
    "nickname" "text",
    "destination_path" "text" DEFAULT '/'::"text" NOT NULL,
    "utm_source" "text",
    "utm_medium" "text",
    "utm_campaign" "text",
    "utm_content" "text",
    "utm_term" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    CONSTRAINT "channel_links_code_format" CHECK ((("code" !~ '[\s#?&%]'::"text") AND (("length"("code") >= 1) AND ("length"("code") <= 100))))
);


ALTER TABLE "public"."channel_links" OWNER TO "postgres";


COMMENT ON TABLE "public"."channel_links" IS 'A peça distribuída. `code` é o que aparece em /r/<code>. As colunas utm_* são congeladas na criação de propósito: renomear a campanha não pode reescrever o significado de links já distribuídos. TP-7 7B/7D.';



CREATE TABLE IF NOT EXISTS "public"."channel_mediums" (
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text"
);


ALTER TABLE "public"."channel_mediums" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."channels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "owner_name" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    CONSTRAINT "channels_slug_format" CHECK (("slug" ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::"text"))
);


ALTER TABLE "public"."channels" OWNER TO "postgres";


COMMENT ON TABLE "public"."channels" IS 'Quem divulga (o ator). Substitui a tabela influencers, que virou depósito: dos 82 registros só 30 eram pessoas. `type` é o utm_medium e vem de lista fechada. TP-7 7B.';



CREATE TABLE IF NOT EXISTS "public"."chat_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "sender" "text",
    "content" "text",
    "workflow" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "session_id" "text",
    CONSTRAINT "chat_messages_sender_check" CHECK (("sender" = ANY (ARRAY['user'::"text", 'cloudinha'::"text", 'system'::"text"])))
);


ALTER TABLE "public"."chat_messages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."chat_messages"."session_id" IS 'UUID da sessão ativa. Permite agrupar mensagens por conversa.';



CREATE TABLE IF NOT EXISTS "public"."cities" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "state" "text" NOT NULL,
    "latitude" double precision,
    "longitude" double precision,
    "ibge_code" integer
);


ALTER TABLE "public"."cities" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cities_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."cities_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."cities_id_seq" OWNED BY "public"."cities"."id";



CREATE TABLE IF NOT EXISTS "public"."cloudinha_starters" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "page_route" "text" NOT NULL,
    "route_priority" integer DEFAULT 0,
    "intro_message" "text",
    "starters" "jsonb" DEFAULT '[]'::"jsonb",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."cloudinha_starters" OWNER TO "postgres";


COMMENT ON TABLE "public"."cloudinha_starters" IS 'Conversation starters estáticos por rota, gerenciados via Admin /agent-config.';



COMMENT ON COLUMN "public"."cloudinha_starters"."page_route" IS 'Rota do app (ex: /oportunidades, /courses/:id). Maior route_priority prevalece em colisões.';



COMMENT ON COLUMN "public"."cloudinha_starters"."starters" IS 'Array JSON de strings: ["Pergunta 1?", "Pergunta 2?", "Pergunta 3?"]';



CREATE TABLE IF NOT EXISTS "public"."concurrency_tag_rules" (
    "type_name" "text" NOT NULL,
    "tags" "jsonb"
);


ALTER TABLE "public"."concurrency_tag_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."conversions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "channel_link_id" "uuid",
    "event_type" "text" NOT NULL,
    "value" numeric,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."conversions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."course_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_key" "text" NOT NULL,
    "group_label" "text" NOT NULL,
    "courses" "text"[] NOT NULL
);


ALTER TABLE "public"."course_groups" OWNER TO "postgres";


COMMENT ON TABLE "public"."course_groups" IS 'Classificação de cursos por grande área CNPq/MEC. Permite match por afinidade quando o curso exato não existe no ciclo ativo.';



CREATE TABLE IF NOT EXISTS "public"."engagement_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid",
    "anonymous_id" "text",
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid",
    "unified_opportunity_id" "text",
    "channel_link_id" "uuid",
    "destination_url" "text",
    "source" "text" DEFAULT 'app'::"text" NOT NULL,
    "event_count" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "engagement_events_channel_link_identified" CHECK ((("entity_type" <> 'channel_link'::"text") OR ("channel_link_id" IS NOT NULL))),
    CONSTRAINT "engagement_events_entity_identified" CHECK ((("entity_type" = 'channel_link'::"text") OR ("entity_id" IS NOT NULL) OR ("unified_opportunity_id" IS NOT NULL))),
    CONSTRAINT "engagement_events_entity_type_check" CHECK (("entity_type" = ANY (ARRAY['partner_opportunity'::"text", 'mec_opportunity'::"text", 'institution'::"text", 'course'::"text", 'channel_link'::"text"]))),
    CONSTRAINT "engagement_events_event_count_check" CHECK (("event_count" > 0)),
    CONSTRAINT "engagement_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['card_view'::"text", 'card_click'::"text", 'redirect'::"text"]))),
    CONSTRAINT "engagement_events_has_subject" CHECK ((("user_id" IS NOT NULL) OR ("anonymous_id" IS NOT NULL))),
    CONSTRAINT "engagement_events_redirect_needs_url" CHECK ((("event_type" <> 'redirect'::"text") OR ("destination_url" IS NOT NULL)))
);


ALTER TABLE "public"."engagement_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."engagement_events" IS 'Fonte única de eventos de engajamento (ADR-0022): card_view, card_click e redirect, para parceiro e MEC. Substitui partners_click e external_redirect_clicks. Métricas históricas devem usar SUM(event_count), nunca COUNT(*) — linhas com source começando em legacy_ representam agregados. TP-2 2a.';



COMMENT ON COLUMN "public"."engagement_events"."channel_link_id" IS 'Link de canal que originou a visita (TP-7). FK adicionada na migration do modelo de canal.';



COMMENT ON COLUMN "public"."engagement_events"."event_count" IS '1 em evento individual; N em linha originada de agregado legado. Sempre agregar com SUM(event_count).';



CREATE TABLE IF NOT EXISTS "public"."etl_run_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "program_id" "uuid",
    "etl_type" "text" NOT NULL,
    "status" "text" NOT NULL,
    "records_processed" integer,
    "errors" "text",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "user_id" "uuid",
    "user_name" "text",
    "backend_pid" integer,
    CONSTRAINT "etl_run_logs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'success'::"text", 'error'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."etl_run_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_redirect_clicks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "redirect_url" "text" NOT NULL,
    "source" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."external_redirect_clicks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."home_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "section_type" "text" NOT NULL,
    "data_source" "text" NOT NULL,
    "display_order" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "target_states" "text"[],
    "target_onboarding_status" "text",
    "config" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "home_sections_data_source_check" CHECK (("data_source" = ANY (ARRAY['partner_opportunities'::"text", 'recent_opportunities'::"text", 'match_results'::"text", 'institutions'::"text", 'important_dates'::"text", 'static'::"text", 'featured_opportunities'::"text", 'institutions_with_open_opps'::"text"]))),
    CONSTRAINT "home_sections_section_type_check" CHECK (("section_type" = ANY (ARRAY['opportunity_carousel'::"text", 'institution_carousel'::"text", 'match_carousel'::"text", 'dates'::"text", 'hero_search'::"text", 'dynamic_cta'::"text"])))
);


ALTER TABLE "public"."home_sections" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_sections" IS 'CMS dinâmico da Home App. Leitura pública (App), escrita apenas para usuários autenticados (Admin).';



CREATE TABLE IF NOT EXISTS "public"."influencers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."influencers" OWNER TO "postgres";


COMMENT ON TABLE "public"."influencers" IS 'Registry of influencer referral codes';



CREATE TABLE IF NOT EXISTS "public"."knowledge_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "label" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."knowledge_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_document_opportunities" (
    "document_id" "uuid" NOT NULL,
    "partner_opportunity_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."knowledge_document_opportunities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_document_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "version_number" integer NOT NULL,
    "storage_path" "text" NOT NULL,
    "change_summary" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."knowledge_document_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "category_id" "uuid",
    "storage_path" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "current_version" integer DEFAULT 1 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "partner_id" "uuid"
);


ALTER TABLE "public"."knowledge_documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_keywords" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "keyword" "text" NOT NULL
);


ALTER TABLE "public"."knowledge_keywords" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."learning_examples" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "intent_category" "text",
    "input_query" "text" NOT NULL,
    "ideal_output" "text" NOT NULL,
    "reasoning" "text",
    "source" "text",
    "embedding" "public"."vector"(768),
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."learning_examples" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "weight_key" "text" NOT NULL,
    "weight_value" numeric DEFAULT 1.0 NOT NULL,
    "description" "text",
    "category" "text" DEFAULT 'general'::"text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."match_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."match_config" IS 'Pesos e multiplicadores do algoritmo de match. Editáveis via Admin /match-engine.';



COMMENT ON COLUMN "public"."match_config"."weight_key" IS 'Chave única do peso (ex: enem_weight, income_weight, partner_boost, location_weight).';



COMMENT ON COLUMN "public"."match_config"."weight_value" IS 'Valor numérico do multiplicador (ex: 1.15 para partner_boost).';



CREATE TABLE IF NOT EXISTS "public"."moderation_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "message_content" "text" NOT NULL,
    "agent_reasoning" "text",
    "flagged_category" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."moderation_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."moderation_logs" IS 'Logs of messages flagged by the Cloudinha agent moderation system';



CREATE TABLE IF NOT EXISTS "public"."nubo_student_whitelist" (
    "phone_number" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."nubo_student_whitelist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."opportunity_phases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "opportunity_id" "uuid" NOT NULL,
    "name" character varying(100) NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."opportunity_phases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partner_forms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "field_name" "text" NOT NULL,
    "question_text" "text" NOT NULL,
    "data_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "options" "jsonb",
    "mapping_source" "text",
    "is_criterion" boolean DEFAULT false NOT NULL,
    "criterion_rule" "jsonb",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "step_id" "uuid",
    "optional" boolean DEFAULT false NOT NULL,
    "maskking" "text",
    "conditional_rule" "jsonb",
    "criterion_type" "text" DEFAULT 'eligibility'::"text",
    "ui_component" character varying(50),
    CONSTRAINT "partner_forms_criterion_type_check" CHECK (("criterion_type" = ANY (ARRAY['eligibility'::"text", 'priority'::"text"])))
);


ALTER TABLE "public"."partner_forms" OWNER TO "postgres";


COMMENT ON COLUMN "public"."partner_forms"."maskking" IS 'Input mask and validation type: cpf, cnpj, phone, cep, brl, email, date, number';



COMMENT ON COLUMN "public"."partner_forms"."ui_component" IS 'Tipo de componente de UI do input (ex. textarea, cpf_input, phone_input, etc)';



CREATE TABLE IF NOT EXISTS "public"."partner_solicitation_attempts" (
    "id" bigint NOT NULL,
    "ip_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."partner_solicitation_attempts" OWNER TO "postgres";


COMMENT ON TABLE "public"."partner_solicitation_attempts" IS 'Contador de tentativas de submissão de parceria, por hash de IP, para rate limit dentro de submit_partner_solicitation(). Sem policies: inacessível fora da função definer. Purgado automaticamente a cada chamada.';



CREATE SEQUENCE IF NOT EXISTS "public"."partner_solicitation_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."partner_solicitation_attempts_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."partner_solicitation_attempts_id_seq" OWNED BY "public"."partner_solicitation_attempts"."id";



CREATE TABLE IF NOT EXISTS "public"."partner_solicitations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "institution_name" "text" NOT NULL,
    "contact_name" "text" NOT NULL,
    "whatsapp" "text",
    "email" "text",
    "how_did_you_know" "text" NOT NULL,
    "goals" "text"
);


ALTER TABLE "public"."partner_solicitations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partner_steps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "step_name" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "introduction" "text",
    "secret_step" boolean DEFAULT false NOT NULL,
    "is_iterable" boolean DEFAULT false,
    "repeat_limit" integer,
    "conditional_rule" "jsonb"
);


ALTER TABLE "public"."partner_steps" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partners_click" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "clicks" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."partners_click" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partners_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."partners_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platforms" (
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL
);


ALTER TABLE "public"."platforms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawemec" (
    "Código Mantenedora" "text",
    "Razão Social" "text",
    "CNPJ" "text",
    "Natureza Jurídica" "text",
    "Código IES" "text",
    "Instituição(IES)" "text",
    "Sigla" "text",
    "Município" "text",
    "UF" "text",
    "Categoria" "text",
    "CI" "text",
    "Ano CI" "text",
    "CI-EaD" "text",
    "Ano CI-EaD" "text",
    "IGC" "text",
    "Ano IGC" "text",
    "Telefone" "text",
    "Sitio" "text",
    "e-Mail" "text",
    "Endereço Sede" "text",
    "Organização Acadêmica" "text",
    "Tipo de Credenciamento" "text",
    "Categoria Administrativa" "text",
    "Data do Ato de Criação da IES" "text",
    "Reitor/Dirigente Principal" "text",
    "Representante Legal" "text",
    "Sinalizações Vigentes" "text",
    "Situação da IES" "text"
);


ALTER TABLE "public"."rawemec" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawprouni" (
    "NU_ANO" "text",
    "NU_SEMESTRE" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "CO_CAMPUS" "text",
    "NO_CAMPUS" "text",
    "CO_CURSO" "text",
    "NO_CURSO" "text",
    "CO_TURNO" "text",
    "NO_TURNO" "text",
    "CO_TIPO_BOLSA" "text",
    "DS_TIPO_BOLSA" "text",
    "MODALIDADE_DO_CURSO" "text",
    "TP_MODALIDADE" "text",
    "NU_NOTA_CORTE" "text",
    "NO_GRAU" "text",
    "NO_MUNICIPIO_CAMPUS" "text",
    "SG_UF_CAMPUS" "text",
    "Bolsas Ofertadas" "text",
    "Bolsas Ocupadas" "text",
    "BOLSAS_AMPLA_OFERTADA" "text",
    "BOLSAS_COTA_OFERTADA" "text",
    "BOLSAS_AMPLA_OCUPADA" "text",
    "BOLSAS_COTA_OCUPADA" "text"
);


ALTER TABLE "public"."rawprouni" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawsisu" (
    "EDICAO" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "SG_IES" "text",
    "DS_ORGANIZACAO_ACADEMICA" "text",
    "DS_CATEGORIA_ADM" "text",
    "NO_CAMPUS" "text",
    "NO_MUNICIPIO_CAMPUS" "text",
    "SG_UF_CAMPUS" "text",
    "DS_REGIAO_CAMPUS" "text",
    "CO_IES_CURSO" "text",
    "NO_CURSO" "text",
    "DS_GRAU" "text",
    "DS_TURNO" "text",
    "TP_MOD_CONCORRENCIA" "text",
    "TIPO_CONCORRENCIA" "text",
    "DS_MOD_CONCORRENCIA" "text",
    "NU_PERCENTUAL_BONUS" "text",
    "QT_VAGAS_OFERTADAS" "text",
    "NU_NOTACORTE" "text",
    "QT_INSCRICAO" "text",
    "QT_VAGAS_CONCORRENCIA" "text"
);


ALTER TABLE "public"."rawsisu" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawsisuvacancies" (
    "EDICAO" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "SG_IES" "text",
    "DS_ORGANIZACAO_ACADEMICA" "text",
    "DS_CATEGORIA_ADM" "text",
    "NO_CAMPUS" "text",
    "SG_UF_CAMPUS" "text",
    "NO_MUNICIPIO_CAMPUS" "text",
    "DS_REGIAO" "text",
    "CO_IES_CURSO" "text",
    "NO_CURSO" "text",
    "DS_GRAU" "text",
    "DS_TURNO" "text",
    "DS_PERIODICIDADE" "text",
    "QT_SEMESTRE" "text",
    "NU_VAGAS_AUTORIZADAS" "text",
    "QT_VAGAS_OFERTADAS" "text",
    "NU_PERCENTUAL_BONUS" "text",
    "TP_MOD_CONCORRENCIA" "text",
    "TP_COTA" "text",
    "DS_MOD_CONCORRENCIA" "text",
    "PESO_REDACAO" "text",
    "NOTA_MINIMA_REDACAO" "text",
    "PESO_LINGUAGENS" "text",
    "NOTA_MINIMA_LINGUAGENS" "text",
    "PESO_MATEMATICA" "text",
    "NOTA_MINIMA_MATEMATICA" "text",
    "PESO_CIENCIAS_HUMANAS" "text",
    "NOTA_MINIMA_CIENCIAS_HUMANAS" "text",
    "PESO_CIENCIAS_NATUREZA" "text",
    "NOTA_MINIMA_CIENCIAS_NATUREZA" "text",
    "NU_MEDIA_MINIMA_ENEM" "text",
    "PERC_UF_IBGE_PPI" "text",
    "PERC_UF_IBGE_PP" "text",
    "PERC_UF_IBGE_I" "text",
    "PERC_UF_IBGE_Q" "text",
    "PERC_UF_IBGE_PCD" "text",
    "NU_PERC_LEI" "text",
    "NU_PERC_PPI" "text",
    "NU_PERC_PP" "text",
    "NU_PERC_I" "text",
    "NU_PERC_Q" "text",
    "NU_PERC_PCD" "text"
);


ALTER TABLE "public"."rawsisuvacancies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'started'::"text" NOT NULL,
    "answers" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "eligibility_results" "jsonb",
    "phase_id" "uuid",
    "dismissed_phase_id" "uuid",
    CONSTRAINT "student_applications_status_check" CHECK (("status" = ANY (ARRAY['started'::"text", 'eligible'::"text", 'ineligible'::"text", 'submitted'::"text", 'DRAFT'::"text", 'pending'::"text", 'SUBMITTED'::"text", 'redirected'::"text", 'ELIGIBLE'::"text", 'INELIGIBLE'::"text", 'IN_REVIEW'::"text", 'APPROVED'::"text", 'REJECTED'::"text"])))
);


ALTER TABLE "public"."student_applications" OWNER TO "postgres";


COMMENT ON COLUMN "public"."student_applications"."status" IS 'Application status. Supports both lowercase (legacy) and uppercase (standard) variants.';



COMMENT ON COLUMN "public"."student_applications"."phase_id" IS 'Fase específica do processo seletivo (micro-status) do parceiro';



CREATE OR REPLACE VIEW "public"."reversed_student_applications" AS
 SELECT "sa"."id" AS "application_id",
    "sa"."user_id",
    "sa"."partner_id",
    "sa"."status",
    "sa"."created_at",
    "u"."phone" AS "user_phone",
    ("sa"."answers" ->> 'Nome Completo'::"text") AS "nome_completo",
    ("sa"."answers" ->> 'Nome de preferência'::"text") AS "nome_preferencia",
    COALESCE(("sa"."answers" ->> 'Email candidato'::"text"), ("sa"."answers" ->> 'Email'::"text")) AS "email",
    ("sa"."answers" ->> 'Profissão do pai'::"text") AS "profissao_pai",
    ("sa"."answers" ->> 'Nome responsável'::"text") AS "nome_responsavel",
    "sa"."answers" AS "formato_original_json"
   FROM ("public"."student_applications" "sa"
     LEFT JOIN "auth"."users" "u" ON (("u"."id" = "sa"."user_id")))
  WHERE (((COALESCE(("sa"."answers" ->> 'Email candidato'::"text"), ("sa"."answers" ->> 'Email'::"text")) ~ '@.+\.(com|br|net|org)[a-zA-Z0-9]+'::"text") AND (COALESCE(("sa"."answers" ->> 'Email candidato'::"text"), ("sa"."answers" ->> 'Email'::"text")) !~ '@.+\.(com|br|net|org)$'::"text")) OR (("sa"."answers" ->> 'Nome de preferência'::"text") ~ '^[a-z].*[A-Z]$'::"text") OR (("sa"."answers" ->> 'Nome Completo'::"text") ~ '^[a-z].*[A-Z]$'::"text") OR (("sa"."answers")::"text" ~~* ANY (ARRAY['%margatsnI%'::"text", '%ipazstahW%'::"text", '%koobecaF%'::"text", '%eniwodniL%'::"text", '%rotlucirGA%'::"text", '%oriehnegnE%'::"text"])) OR (("sa"."answers")::"text" ~ '[a-zçáàâãéêíóôõú][A-ZÇÁÀÂÃÉÊÍÓÔÕÚ]'::"text"));


ALTER VIEW "public"."reversed_student_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sean_ellis_score" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "submitted_at" timestamp with time zone,
    "full_name" "text",
    "whatsapp_raw" "text",
    "whatsapp_normalized" "text",
    "sisu_subscribed" "text",
    "sisu_courses" "text",
    "sisu_status" "text",
    "sisu_cloudinha_influence" "text",
    "prouni_subscribed" "text",
    "prouni_courses" "text",
    "prouni_cloudinha_influence" "text",
    "prouni_status" "text",
    "disappointment_level" "text",
    "feedback" "text",
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sean_ellis_score" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."states" (
    "uf" character(2) NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."states" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_intents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "command" "text" NOT NULL,
    "trigger_route" "text",
    "trigger_type" "text" DEFAULT 'route_change'::"text" NOT NULL,
    "open_drawer" boolean DEFAULT false,
    "delay_ms" integer DEFAULT 0,
    "trigger_message" "text",
    "description" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "pulsate" boolean DEFAULT false
);


ALTER TABLE "public"."system_intents" OWNER TO "postgres";


COMMENT ON TABLE "public"."system_intents" IS 'Configuração de system intents da Cloudinha, gerenciáveis via Admin /agent-config.';



COMMENT ON COLUMN "public"."system_intents"."command" IS 'Identificador do comando: page_context, get_starters, clear_session, ping.';



COMMENT ON COLUMN "public"."system_intents"."trigger_route" IS 'Regex da rota que dispara o intent automaticamente (ex: ^/oportunidades/.+$). NULL para intents manuais.';



COMMENT ON COLUMN "public"."system_intents"."trigger_type" IS 'Tipo de trigger: route_change (automático por rota), manual (botão), timer (delay fixo).';



COMMENT ON COLUMN "public"."system_intents"."open_drawer" IS 'Se true, a Cloudinha abre o drawer automaticamente ao disparar este intent.';



COMMENT ON COLUMN "public"."system_intents"."delay_ms" IS 'Delay em milissegundos antes de abrir o drawer (só usado se open_drawer=true).';



COMMENT ON COLUMN "public"."system_intents"."trigger_message" IS 'Mensagem invisível enviada ao pipeline LLM da Cloudinha (como se fosse do usuário, mas oculta na UI). Suporta placeholders: {{title}}, {{institution}}, {{route}}. Ex: "O usuário está vendo a oportunidade {{title}} em {{institution}}. Ofereça ajuda contextual."';



COMMENT ON COLUMN "public"."system_intents"."pulsate" IS 'Se true, a Cloudinha apenas pulsa/notifica sem abrir o drawer automaticamente.';



CREATE TABLE IF NOT EXISTS "public"."user_attribution" (
    "user_id" "uuid" NOT NULL,
    "first_touch_link_id" "uuid",
    "last_touch_link_id" "uuid",
    "first_touch_at" timestamp with time zone,
    "last_touch_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_attribution" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_attribution" IS 'Atribuição de origem por usuário, first e last touch. Separada de user_profiles de propósito. TP-7 7B.';



CREATE TABLE IF NOT EXISTS "public"."user_enem_scores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "year" integer NOT NULL,
    "nota_linguagens" numeric(6,2),
    "nota_ciencias_humanas" numeric(6,2),
    "nota_ciencias_natureza" numeric(6,2),
    "nota_matematica" numeric(6,2),
    "nota_redacao" numeric(6,2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_treineiro" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."user_enem_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_favorites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "course_id" "uuid",
    "partner_opportunities_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "institution_id" "uuid",
    CONSTRAINT "user_favorites_target_check" CHECK (((("course_id" IS NOT NULL) AND ("partner_opportunities_id" IS NULL) AND ("institution_id" IS NULL)) OR (("course_id" IS NULL) AND ("partner_opportunities_id" IS NOT NULL) AND ("institution_id" IS NULL)) OR (("course_id" IS NULL) AND ("partner_opportunities_id" IS NULL) AND ("institution_id" IS NOT NULL))))
);


ALTER TABLE "public"."user_favorites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_income" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "family_count" integer,
    "social_benefits" numeric(10,2),
    "alimony" numeric(10,2),
    "member_incomes" "jsonb" DEFAULT '[]'::"jsonb",
    "per_capita_income" numeric(10,2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_income" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_opportunity_matches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "unified_opportunity_id" "text" NOT NULL,
    "match_score" numeric(5,2) DEFAULT 0.00 NOT NULL,
    "match_details" "jsonb" DEFAULT '{}'::"jsonb",
    "generated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_opportunity_matches" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_opportunity_matches" IS 'Resultados de match por perfil. Regenerados ao clicar "Gerar Match" ou "Refazer Match".';



COMMENT ON COLUMN "public"."user_opportunity_matches"."unified_opportunity_id" IS 'ID da v_unified_opportunities (ex: mec_123 ou partner_456).';



COMMENT ON COLUMN "public"."user_opportunity_matches"."match_score" IS 'Percentual de compatibilidade (0.00 a 100.00).';



COMMENT ON COLUMN "public"."user_opportunity_matches"."match_details" IS 'Breakdown: { enem_component: 30.5, income_component: 18.0, ... }';



CREATE TABLE IF NOT EXISTS "public"."user_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "permission" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "course_interest" "text"[],
    "enem_score" numeric(10,2),
    "preferred_shifts" "text"[],
    "university_preference" "text",
    "program_preference" "text",
    "family_income_per_capita" numeric(10,2),
    "quota_types" "text"[],
    "location_preference" "text",
    "state_preference" "text",
    "device_latitude" numeric,
    "device_longitude" numeric,
    "workflow_data" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "registration_step" "text" DEFAULT 'intro'::"text",
    "match_status" "text" DEFAULT 'idle'::"text",
    "last_match_at" timestamp with time zone,
    CONSTRAINT "user_preferences_program_preference_check" CHECK (("program_preference" = ANY (ARRAY['sisu'::"text", 'prouni'::"text", 'indiferente'::"text"]))),
    CONSTRAINT "user_preferences_university_preference_check" CHECK (("university_preference" = ANY (ARRAY['publica'::"text", 'privada'::"text", 'indiferente'::"text"])))
);


ALTER TABLE "public"."user_preferences" OWNER TO "postgres";


COMMENT ON COLUMN "public"."user_preferences"."program_preference" IS 'Programa de interesse: sisu (públicas), prouni (privadas), ou indiferente';



COMMENT ON COLUMN "public"."user_preferences"."workflow_data" IS 'Armazena estado interno dos workflows para persistência entre sessões';



CREATE TABLE IF NOT EXISTS "public"."user_profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text",
    "age" integer,
    "city" "text",
    "education" "text",
    "onboarding_completed" boolean DEFAULT false,
    "active_workflow" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "referral_source" "text",
    "state" "text",
    "is_nubo_student" boolean DEFAULT false,
    "zip_code" "text",
    "street" "text",
    "street_number" "text",
    "complement" "text",
    "passport_phase" "text" DEFAULT 'INTRO'::"text",
    "workflow_data" "jsonb",
    "relationship" "text",
    "isdependent" boolean DEFAULT false,
    "parent_user_id" "uuid",
    "current_dependent_id" "uuid",
    "education_year" "text",
    "active_application_target_id" "uuid",
    "furthest_passport_phase" "text" DEFAULT 'INTRO'::"text",
    "birth_date" "date",
    "neighborhood" "text",
    "country" "text",
    "outside_brazil" boolean DEFAULT false,
    "avatar_url" "text",
    "cpf" character varying(20),
    "phone" "text",
    "race" "text",
    "school_type" "text",
    CONSTRAINT "user_profiles_furthest_passport_phase_check" CHECK (("furthest_passport_phase" = ANY (ARRAY['INTRO'::"text", 'ONBOARDING'::"text", 'ASK_DEPENDENT'::"text", 'DEPENDENT_ONBOARDING'::"text", 'PROGRAM_MATCH'::"text", 'EVALUATE'::"text", 'CONCLUDED'::"text"]))),
    CONSTRAINT "user_profiles_passport_phase_check" CHECK (("passport_phase" = ANY (ARRAY['INTRO'::"text", 'ONBOARDING'::"text", 'ASK_DEPENDENT'::"text", 'DEPENDENT_ONBOARDING'::"text", 'PROGRAM_MATCH'::"text", 'EVALUATE'::"text", 'CONCLUDED'::"text"])))
);


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."user_profiles"."referral_source" IS 'Source of the referral (e.g. influencer code) obtained from URL parameter "ref"';



COMMENT ON COLUMN "public"."user_profiles"."active_application_target_id" IS 'ID of the profile (self or dependent) currently being evaluated for an application.';



CREATE TABLE IF NOT EXISTS "public"."user_rate_limits" (
    "user_id" "uuid" NOT NULL,
    "last_message_at" timestamp with time zone DEFAULT "now"(),
    "message_count_window" integer DEFAULT 0
);


ALTER TABLE "public"."user_rate_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users_metadata" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "cognitive_memory" "jsonb" DEFAULT '{}'::"jsonb",
    "last_session_summary" "text",
    "conversation_starters" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."users_metadata" OWNER TO "postgres";


COMMENT ON TABLE "public"."users_metadata" IS 'Estado cognitivo do agente por perfil. Cada membro da família tem seu LTM único.';



COMMENT ON COLUMN "public"."users_metadata"."cognitive_memory" IS 'Sumário cognitivo condensado (~500 tokens). Fatos persistentes: objetivos, dificuldades, área de interesse.';



COMMENT ON COLUMN "public"."users_metadata"."last_session_summary" IS 'Resumo da última sessão (input para condensação).';



COMMENT ON COLUMN "public"."users_metadata"."conversation_starters" IS 'Últimas sugestões dinâmicas do Reasoning Agent, indexadas por page_route.';



CREATE OR REPLACE VIEW "public"."v_unified_institutions" AS
 WITH "inst_opps" AS (
         SELECT "v"."institution_id",
            "array_agg"(DISTINCT "v"."opportunity_type") AS "opp_types",
            "count"(*) FILTER (WHERE ("v"."status" = 'opened'::"text")) AS "open_opportunities_count"
           FROM "public"."v_unified_opportunities" "v"
          GROUP BY "v"."institution_id"
        )
 SELECT "i"."id",
    "i"."name",
    COALESCE("pi"."location",
        CASE
            WHEN (("ie"."city" IS NOT NULL) AND ("ie"."state" IS NOT NULL)) THEN (("ie"."city" || ' - '::"text") || "ie"."state")
            WHEN ("ie"."city" IS NOT NULL) THEN "ie"."city"
            WHEN ("ie"."state" IS NOT NULL) THEN "ie"."state"
            ELSE ( SELECT (("c"."city" || ' - '::"text") || "c"."state")
               FROM "public"."campus" "c"
              WHERE (("c"."institution_id" = "i"."id") AND ("c"."city" IS NOT NULL))
             LIMIT 1)
        END) AS "location",
    "pi"."logo_url",
    "pi"."cover_url",
    "pi"."brand_color",
    "pi"."description",
    "pi"."website_url",
    "sisu"."acronym",
        CASE
            WHEN ("i"."is_partner" IS TRUE) THEN 'partner'::"text"
            ELSE 'mec'::"text"
        END AS "type",
    "i"."is_partner",
    "io"."opp_types",
    COALESCE("io"."open_opportunities_count", (0)::bigint) AS "open_opportunities_count",
    (COALESCE("io"."open_opportunities_count", (0)::bigint) > 0) AS "has_open_opportunities",
    COALESCE("sisu"."academic_organization", "ie"."academic_organization") AS "academic_organization",
    COALESCE("sisu"."administrative_category", "ie"."administrative_category") AS "administrative_category",
        CASE
            WHEN ("i"."is_partner" IS TRUE) THEN NULL::"text"
            ELSE "ie"."igc"
        END AS "igc",
        CASE
            WHEN ("i"."is_partner" IS TRUE) THEN NULL::"text"
            ELSE "ie"."ci"
        END AS "ci",
        CASE
            WHEN ("i"."is_partner" IS TRUE) THEN NULL::"text"
            ELSE "ie"."ci_ead"
        END AS "ci_ead",
        CASE
            WHEN ("i"."is_partner" IS TRUE) THEN NULL::"text"
            ELSE "ie"."legal_nature"
        END AS "legal_nature",
        CASE
            WHEN ("i"."is_partner" IS TRUE) THEN NULL::"text"
            ELSE "ie"."maintainer_name"
        END AS "maintainer_name"
   FROM (((("public"."institutions" "i"
     LEFT JOIN "public"."partner_institutions" "pi" ON (("pi"."institution_id" = "i"."id")))
     LEFT JOIN "public"."institutions_info_emec" "ie" ON (("ie"."institution_id" = "i"."id")))
     LEFT JOIN "public"."institutions_info_sisu" "sisu" ON (("sisu"."institution_id" = "i"."id")))
     LEFT JOIN "inst_opps" "io" ON (("io"."institution_id" = "i"."id")));


ALTER VIEW "public"."v_unified_institutions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_user_funnel" AS
 WITH "user_apps" AS (
         SELECT "student_applications"."user_id",
            "count"(*) AS "total_applications_started",
            "count"(*) FILTER (WHERE ("student_applications"."status" = 'SUBMITTED'::"text")) AS "total_applications_submitted"
           FROM "public"."student_applications"
          GROUP BY "student_applications"."user_id"
        )
 SELECT "up"."id" AS "user_id",
    "up"."full_name",
    "up"."created_at",
    "up"."isdependent",
    "up"."parent_user_id",
    "up"."passport_phase",
    "up"."furthest_passport_phase",
    (("up"."active_workflow" = 'passport_workflow'::"text") OR ("up"."furthest_passport_phase" IS NOT NULL)) AS "passport_started",
    COALESCE("ua"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("ua"."total_applications_submitted", (0)::bigint) AS "total_applications_submitted"
   FROM ("public"."user_profiles" "up"
     LEFT JOIN "user_apps" "ua" ON (("ua"."user_id" = "up"."id")))
  WHERE ("up"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone);


ALTER VIEW "public"."vw_admin_user_funnel" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_favorite_courses_ranking" AS
 SELECT "c"."id" AS "course_id",
    "c"."course_name",
    "cp"."name" AS "campus_name",
    "i"."name" AS "institution_name",
    "count"("uf"."user_id") AS "sum_user"
   FROM ((("public"."user_favorites" "uf"
     JOIN "public"."courses" "c" ON (("uf"."course_id" = "c"."id")))
     JOIN "public"."campus" "cp" ON (("c"."campus_id" = "cp"."id")))
     JOIN "public"."institutions" "i" ON (("cp"."institution_id" = "i"."id")))
  WHERE ("uf"."course_id" IS NOT NULL)
  GROUP BY "c"."id", "c"."course_name", "cp"."name", "i"."name"
  ORDER BY ("count"("uf"."user_id")) DESC;


ALTER VIEW "public"."vw_favorite_courses_ranking" OWNER TO "postgres";


COMMENT ON VIEW "public"."vw_favorite_courses_ranking" IS 'View for exporting a ranking of favorite courses by user count.';



CREATE OR REPLACE VIEW "public"."vw_partner_application_details" AS
 SELECT "sa"."id" AS "application_id",
    "sa"."partner_id",
    "sa"."user_id",
    "up"."full_name" AS "student_name",
    "sa"."status",
    "sa"."created_at",
    "sa"."updated_at",
    ( SELECT "count"(*) AS "count"
           FROM "jsonb_object_keys"(
                CASE
                    WHEN ("jsonb_typeof"("sa"."answers") = 'object'::"text") THEN "sa"."answers"
                    ELSE '{}'::"jsonb"
                END) "jsonb_object_keys"("jsonb_object_keys")) AS "total_answers_filled"
   FROM ("public"."student_applications" "sa"
     JOIN "public"."user_profiles" "up" ON (("up"."id" = "sa"."user_id")));


ALTER VIEW "public"."vw_partner_application_details" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_partner_application_completion_buckets" AS
 WITH "partner_form_counts" AS (
         SELECT "partner_forms"."partner_id",
            "count"(*) AS "total_forms"
           FROM "public"."partner_forms"
          GROUP BY "partner_forms"."partner_id"
        ), "application_percentages" AS (
         SELECT "a"."application_id",
            "a"."partner_id",
            "a"."status",
            "a"."total_answers_filled",
            COALESCE("fc"."total_forms", (0)::bigint) AS "total_forms",
                CASE
                    WHEN ("a"."status" = 'SUBMITTED'::"text") THEN (100)::bigint
                    WHEN (COALESCE("fc"."total_forms", (0)::bigint) = 0) THEN (0)::bigint
                    ELSE LEAST((100)::bigint, (("a"."total_answers_filled" * 100) / "fc"."total_forms"))
                END AS "completion_percent"
           FROM ("public"."vw_partner_application_details" "a"
             LEFT JOIN "partner_form_counts" "fc" ON (("a"."partner_id" = "fc"."partner_id")))
        )
 SELECT "partner_id",
        CASE
            WHEN ("completion_percent" <= 25) THEN '1. Até 25%'::"text"
            WHEN ("completion_percent" <= 50) THEN '2. Até 50%'::"text"
            WHEN ("completion_percent" <= 75) THEN '3. Até 75%'::"text"
            ELSE '4. Até 100%'::"text"
        END AS "completion_bucket",
    "count"(*) AS "applications_count"
   FROM "application_percentages"
  GROUP BY "partner_id",
        CASE
            WHEN ("completion_percent" <= 25) THEN '1. Até 25%'::"text"
            WHEN ("completion_percent" <= 50) THEN '2. Até 50%'::"text"
            WHEN ("completion_percent" <= 75) THEN '3. Até 75%'::"text"
            ELSE '4. Até 100%'::"text"
        END;


ALTER VIEW "public"."vw_partner_application_completion_buckets" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_partner_funnel" AS
 WITH "partner_clicks" AS (
         SELECT "po"."institution_id",
            "count"(DISTINCT "partners_click"."user_id") AS "total_unique_clicks"
           FROM ("public"."partners_click"
             JOIN "public"."partner_opportunities" "po" ON (("partners_click"."partner_id" = "po"."id")))
          GROUP BY "po"."institution_id"
        ), "partner_apps" AS (
         SELECT "po"."institution_id",
            "count"(DISTINCT "student_applications"."user_id") AS "total_applications_started",
            "count"(DISTINCT
                CASE
                    WHEN (("student_applications"."status" = 'SUBMITTED'::"text") OR ("student_applications"."status" = 'redirected'::"text")) THEN "student_applications"."user_id"
                    ELSE NULL::"uuid"
                END) AS "total_applications_completed"
           FROM ("public"."student_applications"
             JOIN "public"."partner_opportunities" "po" ON (("student_applications"."partner_id" = "po"."id")))
          GROUP BY "po"."institution_id"
        )
 SELECT "i"."id" AS "partner_id",
    "i"."name" AS "partner_name",
    COALESCE("pc"."total_unique_clicks", (0)::bigint) AS "total_unique_clicks",
    COALESCE("pa"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("pa"."total_applications_completed", (0)::bigint) AS "total_applications_completed"
   FROM (("public"."institutions" "i"
     LEFT JOIN "partner_clicks" "pc" ON (("i"."id" = "pc"."institution_id")))
     LEFT JOIN "partner_apps" "pa" ON (("i"."id" = "pa"."institution_id")))
  WHERE ("i"."is_partner" = true);


ALTER VIEW "public"."vw_partner_funnel" OWNER TO "postgres";


ALTER TABLE ONLY "public"."cities" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."cities_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."partner_solicitation_attempts" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."partner_solicitation_attempts_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."admin_alerts"
    ADD CONSTRAINT "admin_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_errors"
    ADD CONSTRAINT "agent_errors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_executions"
    ADD CONSTRAINT "agent_executions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_feedback"
    ADD CONSTRAINT "agent_feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_prompt_versions"
    ADD CONSTRAINT "agent_prompt_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_prompts"
    ADD CONSTRAINT "agent_prompts_agent_key_key" UNIQUE ("agent_key");



ALTER TABLE ONLY "public"."agent_prompts"
    ADD CONSTRAINT "agent_prompts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_turns"
    ADD CONSTRAINT "agent_turns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_insights"
    ADD CONSTRAINT "ai_insights_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campaigns"
    ADD CONSTRAINT "campaigns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campaigns"
    ADD CONSTRAINT "campaigns_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."campus"
    ADD CONSTRAINT "campus_external_code_key" UNIQUE ("external_code");



ALTER TABLE ONLY "public"."campus"
    ADD CONSTRAINT "campus_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."channel_links"
    ADD CONSTRAINT "channel_links_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."channel_links"
    ADD CONSTRAINT "channel_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."channel_mediums"
    ADD CONSTRAINT "channel_mediums_pkey" PRIMARY KEY ("slug");



ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_name_state_key" UNIQUE ("name", "state");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cloudinha_starters"
    ADD CONSTRAINT "cloudinha_starters_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."concurrency_tag_rules"
    ADD CONSTRAINT "concurrency_tag_rules_pkey" PRIMARY KEY ("type_name");



ALTER TABLE ONLY "public"."conversions"
    ADD CONSTRAINT "conversions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_groups"
    ADD CONSTRAINT "course_groups_group_key_key" UNIQUE ("group_key");



ALTER TABLE ONLY "public"."course_groups"
    ADD CONSTRAINT "course_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_campus_id_course_code_key" UNIQUE ("campus_id", "course_code");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."engagement_events"
    ADD CONSTRAINT "engagement_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."etl_run_logs"
    ADD CONSTRAINT "etl_run_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_redirect_clicks"
    ADD CONSTRAINT "external_redirect_clicks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."home_sections"
    ADD CONSTRAINT "home_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."important_dates"
    ADD CONSTRAINT "important_dates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."influencers"
    ADD CONSTRAINT "influencers_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."influencers"
    ADD CONSTRAINT "influencers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."institutions"
    ADD CONSTRAINT "institutions_external_code_key" UNIQUE ("external_code");



ALTER TABLE ONLY "public"."institutions_info_emec"
    ADD CONSTRAINT "institutions_info_emec_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."institutions_info_sisu"
    ADD CONSTRAINT "institutions_info_sisu_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."institutions"
    ADD CONSTRAINT "institutions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."institutions_info_emec"
    ADD CONSTRAINT "institutionsinfoemec_institution_id_key" UNIQUE ("institution_id");



ALTER TABLE ONLY "public"."institutions_info_sisu"
    ADD CONSTRAINT "institutionsinfosisu_institution_id_key" UNIQUE ("institution_id");



ALTER TABLE ONLY "public"."knowledge_categories"
    ADD CONSTRAINT "knowledge_categories_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."knowledge_categories"
    ADD CONSTRAINT "knowledge_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_document_opportunities"
    ADD CONSTRAINT "knowledge_document_opportunities_pkey" PRIMARY KEY ("document_id", "partner_opportunity_id");



ALTER TABLE ONLY "public"."knowledge_document_versions"
    ADD CONSTRAINT "knowledge_document_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_documents"
    ADD CONSTRAINT "knowledge_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_keywords"
    ADD CONSTRAINT "knowledge_keywords_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."learning_examples"
    ADD CONSTRAINT "learning_examples_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_config"
    ADD CONSTRAINT "match_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_config"
    ADD CONSTRAINT "match_config_weight_key_key" UNIQUE ("weight_key");



ALTER TABLE ONLY "public"."moderation_logs"
    ADD CONSTRAINT "moderation_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nubo_student_whitelist"
    ADD CONSTRAINT "nubo_student_whitelist_pkey" PRIMARY KEY ("phone_number");



ALTER TABLE ONLY "public"."opportunities"
    ADD CONSTRAINT "opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."opportunities_prouni_vacancies"
    ADD CONSTRAINT "opportunities_prouni_vacancies_pkey" PRIMARY KEY ("opportunity_id");



ALTER TABLE ONLY "public"."opportunities_sisu_vacancies"
    ADD CONSTRAINT "opportunitiessisuvacancies_opportunity_id_key" UNIQUE ("opportunity_id");



ALTER TABLE ONLY "public"."opportunities_sisu_vacancies"
    ADD CONSTRAINT "opportunitiessisuvacancies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."opportunity_phases"
    ADD CONSTRAINT "opportunity_phases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_partner_id_field_name_key" UNIQUE ("partner_id", "field_name");



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_institutions"
    ADD CONSTRAINT "partner_institutions_pkey" PRIMARY KEY ("institution_id");



ALTER TABLE ONLY "public"."partner_opportunities"
    ADD CONSTRAINT "partner_opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_solicitation_attempts"
    ADD CONSTRAINT "partner_solicitation_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_solicitations"
    ADD CONSTRAINT "partner_solicitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_steps"
    ADD CONSTRAINT "partner_steps_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partners_click"
    ADD CONSTRAINT "partners_click_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partners_click"
    ADD CONSTRAINT "partners_click_user_id_partner_id_key" UNIQUE ("user_id", "partner_id");



ALTER TABLE ONLY "public"."partners"
    ADD CONSTRAINT "partners_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partners_users"
    ADD CONSTRAINT "partners_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partners_users"
    ADD CONSTRAINT "partners_users_user_id_partner_id_key" UNIQUE ("user_id", "partner_id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_pkey" PRIMARY KEY ("slug");



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_type_cycle_year_cycle_semester_key" UNIQUE ("type", "cycle_year", "cycle_semester");



ALTER TABLE ONLY "public"."sean_ellis_score"
    ADD CONSTRAINT "sean_ellis_score_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."states"
    ADD CONSTRAINT "states_pkey" PRIMARY KEY ("uf");



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_user_id_partner_id_key" UNIQUE ("user_id", "partner_id");



ALTER TABLE ONLY "public"."system_intents"
    ADD CONSTRAINT "system_intents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_attribution"
    ADD CONSTRAINT "user_attribution_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_enem_scores"
    ADD CONSTRAINT "user_enem_scores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_enem_scores"
    ADD CONSTRAINT "user_enem_scores_user_id_year_key" UNIQUE ("user_id", "year");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_course_unique" UNIQUE ("user_id", "course_id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_partner_unique" UNIQUE ("user_id", "partner_opportunities_id");



ALTER TABLE ONLY "public"."user_income"
    ADD CONSTRAINT "user_income_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_income"
    ADD CONSTRAINT "user_income_user_id_unique" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_opportunity_matches"
    ADD CONSTRAINT "user_opportunity_matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_id_permission_key" UNIQUE ("user_id", "permission");



ALTER TABLE ONLY "public"."user_preferences"
    ADD CONSTRAINT "user_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_preferences"
    ADD CONSTRAINT "user_preferences_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_rate_limits"
    ADD CONSTRAINT "user_rate_limits_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."users_metadata"
    ADD CONSTRAINT "users_metadata_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users_metadata"
    ADD CONSTRAINT "users_metadata_profile_id_key" UNIQUE ("profile_id");



CREATE INDEX "channel_links_campaign_idx" ON "public"."channel_links" USING "btree" ("campaign_id");



CREATE INDEX "channel_links_channel_idx" ON "public"."channel_links" USING "btree" ("channel_id");



CREATE INDEX "conversions_link_idx" ON "public"."conversions" USING "btree" ("channel_link_id", "occurred_at" DESC);



CREATE INDEX "conversions_user_idx" ON "public"."conversions" USING "btree" ("user_id", "occurred_at" DESC);



CREATE INDEX "engagement_events_anon_idx" ON "public"."engagement_events" USING "btree" ("anonymous_id", "occurred_at" DESC) WHERE ("anonymous_id" IS NOT NULL);



CREATE INDEX "engagement_events_anon_recent_idx" ON "public"."engagement_events" USING "btree" ("anonymous_id", "event_type", "occurred_at" DESC) WHERE ("anonymous_id" IS NOT NULL);



CREATE INDEX "engagement_events_channel_idx" ON "public"."engagement_events" USING "btree" ("channel_link_id", "occurred_at" DESC) WHERE ("channel_link_id" IS NOT NULL);



CREATE INDEX "engagement_events_entity_idx" ON "public"."engagement_events" USING "btree" ("entity_type", "entity_id", "occurred_at" DESC);



CREATE UNIQUE INDEX "engagement_events_event_id_key" ON "public"."engagement_events" USING "btree" ("event_id");



CREATE INDEX "engagement_events_occurred_idx" ON "public"."engagement_events" USING "btree" ("occurred_at" DESC);



CREATE INDEX "engagement_events_type_occurred_idx" ON "public"."engagement_events" USING "btree" ("event_type", "occurred_at" DESC);



CREATE INDEX "engagement_events_user_idx" ON "public"."engagement_events" USING "btree" ("user_id", "occurred_at" DESC) WHERE ("user_id" IS NOT NULL);



CREATE INDEX "idx_admin_alerts_pending" ON "public"."admin_alerts" USING "btree" ("created_at" DESC) WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_admin_alerts_type_created" ON "public"."admin_alerts" USING "btree" ("alert_type", "created_at" DESC);



CREATE INDEX "idx_agent_prompt_versions_key" ON "public"."agent_prompt_versions" USING "btree" ("agent_key", "created_at" DESC);



CREATE INDEX "idx_agent_turns_created" ON "public"."agent_turns" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_agent_turns_session" ON "public"."agent_turns" USING "btree" ("session_id");



CREATE INDEX "idx_agent_turns_session_created" ON "public"."agent_turns" USING "btree" ("session_id", "created_at" DESC);



CREATE INDEX "idx_agent_turns_steps" ON "public"."agent_turns" USING "gin" ("steps");



CREATE INDEX "idx_agent_turns_user" ON "public"."agent_turns" USING "btree" ("user_id");



CREATE INDEX "idx_ai_insights_created_at" ON "public"."ai_insights" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_campus_city_trgm_simple" ON "public"."campus" USING "gin" ("city" "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_city_unaccent" ON "public"."campus" USING "gin" ("public"."f_unaccent"("city") "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_city_unaccent_gin" ON "public"."campus" USING "gin" ("public"."f_unaccent"("city") "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_institution_id" ON "public"."campus" USING "btree" ("institution_id");



CREATE INDEX "idx_campus_join_opt" ON "public"."campus" USING "btree" ("institution_id", "name", "city");



CREATE INDEX "idx_campus_lat_long" ON "public"."campus" USING "gist" ("point"("longitude", "latitude"));



CREATE INDEX "idx_campus_state_unaccent" ON "public"."campus" USING "gin" ("public"."f_unaccent"("state") "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_state_unaccent_gin" ON "public"."campus" USING "gin" ("public"."f_unaccent"("state") "public"."gin_trgm_ops");



CREATE INDEX "idx_chat_messages_session" ON "public"."chat_messages" USING "btree" ("session_id");



CREATE INDEX "idx_chat_messages_user_created_at" ON "public"."chat_messages" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_cities_name_state" ON "public"."cities" USING "btree" ("name", "state");



CREATE INDEX "idx_cities_state" ON "public"."cities" USING "btree" ("state");



CREATE INDEX "idx_cities_unaccent_name" ON "public"."cities" USING "btree" ("public"."f_unaccent"("lower"("name")));



CREATE INDEX "idx_cloudinha_starters_route" ON "public"."cloudinha_starters" USING "btree" ("page_route");



CREATE INDEX "idx_course_groups_courses" ON "public"."course_groups" USING "gin" ("courses");



CREATE INDEX "idx_courses_campus_id" ON "public"."courses" USING "btree" ("campus_id");



CREATE INDEX "idx_courses_course_name_trgm" ON "public"."courses" USING "gin" ("course_name" "public"."gin_trgm_ops");



CREATE INDEX "idx_courses_course_name_unaccent" ON "public"."courses" USING "gin" ("public"."f_unaccent"("course_name") "public"."gin_trgm_ops");



CREATE INDEX "idx_courses_join_opt" ON "public"."courses" USING "btree" ("campus_id", "course_code");



CREATE INDEX "idx_courses_name_unaccent_gin" ON "public"."courses" USING "gin" ("public"."f_unaccent"("course_name") "public"."gin_trgm_ops");



CREATE INDEX "idx_institutions_external_code" ON "public"."institutions" USING "btree" ("external_code");



CREATE INDEX "idx_institutions_is_partner" ON "public"."institutions" USING "btree" ("is_partner") WHERE ("is_partner" = true);



CREATE INDEX "idx_institutions_name_trgm" ON "public"."institutions" USING "gin" ("name" "public"."gin_trgm_ops");



CREATE INDEX "idx_institutions_name_unaccent_gin" ON "public"."institutions" USING "gin" ("public"."f_unaccent"("name") "public"."gin_trgm_ops");



CREATE INDEX "idx_institutionsinfoemec_admin_cat_gin" ON "public"."institutions_info_emec" USING "gin" ("public"."f_unaccent"("administrative_category") "public"."gin_trgm_ops");



CREATE INDEX "idx_knowledge_document_opportunities_opportunity" ON "public"."knowledge_document_opportunities" USING "btree" ("partner_opportunity_id");



CREATE INDEX "idx_knowledge_documents_active" ON "public"."knowledge_documents" USING "btree" ("is_active");



CREATE INDEX "idx_knowledge_documents_category" ON "public"."knowledge_documents" USING "btree" ("category_id");



CREATE INDEX "idx_knowledge_keywords_keyword" ON "public"."knowledge_keywords" USING "gin" ("keyword" "public"."gin_trgm_ops");



CREATE UNIQUE INDEX "idx_knowledge_keywords_unique" ON "public"."knowledge_keywords" USING "btree" ("document_id", "keyword");



CREATE INDEX "idx_knowledge_versions_document" ON "public"."knowledge_document_versions" USING "btree" ("document_id");



CREATE INDEX "idx_opp_sisu_vacancies_opp_id" ON "public"."opportunities_sisu_vacancies" USING "btree" ("opportunity_id");



CREATE INDEX "idx_opportunities_concurrency_tags" ON "public"."opportunities" USING "gin" ("concurrency_tags");



CREATE INDEX "idx_opportunities_concurrency_tags_text" ON "public"."opportunities" USING "gin" ((("concurrency_tags")::"text") "public"."gin_trgm_ops");



CREATE INDEX "idx_opportunities_concurrency_type" ON "public"."opportunities" USING "btree" ("concurrency_type");



CREATE INDEX "idx_opportunities_course_id" ON "public"."opportunities" USING "btree" ("course_id");



CREATE INDEX "idx_opportunities_created_at_desc" ON "public"."opportunities" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_opportunities_cutoff_score" ON "public"."opportunities" USING "btree" ("cutoff_score");



CREATE INDEX "idx_opportunities_join_opt" ON "public"."opportunities" USING "btree" ("course_id", "shift", "concurrency_type", "year", "semester");



CREATE INDEX "idx_opportunities_search_lookup" ON "public"."opportunities" USING "btree" ("year", "semester", "opportunity_type", "cutoff_score");



CREATE INDEX "idx_opportunities_semester_type_year" ON "public"."opportunities" USING "btree" ("semester", "opportunity_type", "year");



CREATE INDEX "idx_opportunities_shift" ON "public"."opportunities" USING "btree" ("shift");



CREATE INDEX "idx_opportunities_timeline_type" ON "public"."opportunities" USING "btree" ("semester", "opportunity_type", "year");



CREATE INDEX "idx_opportunities_type_unaccent" ON "public"."opportunities" USING "btree" ("public"."f_unaccent"("opportunity_type"));



CREATE INDEX "idx_opportunities_type_year_semester" ON "public"."opportunities" USING "btree" ("opportunity_type", "year", "semester");



CREATE INDEX "idx_opportunities_year_semester_type" ON "public"."opportunities" USING "btree" ("year", "semester", "opportunity_type");



CREATE INDEX "idx_partner_forms_partner_id" ON "public"."partner_forms" USING "btree" ("partner_id");



CREATE INDEX "idx_partner_opp_dates" ON "public"."partner_opportunities" USING "btree" ("starts_at", "ends_at") WHERE (("status")::"text" = 'approved'::"text");



CREATE INDEX "idx_partner_opportunities_created_at_desc" ON "public"."partner_opportunities" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_partner_opportunities_status_approved" ON "public"."partner_opportunities" USING "btree" ("status") WHERE (("status")::"text" = 'approved'::"text");



CREATE INDEX "idx_partners_users_partner_id" ON "public"."partners_users" USING "btree" ("partner_id");



CREATE INDEX "idx_partners_users_user_id" ON "public"."partners_users" USING "btree" ("user_id");



CREATE INDEX "idx_rawprouni_etl_batch" ON "public"."rawprouni" USING "btree" ("CO_IES", "CO_CAMPUS", "CO_CURSO", "CO_TURNO", "DS_TIPO_BOLSA");



CREATE INDEX "idx_sisu_vacancies_opportunity_id" ON "public"."opportunities_sisu_vacancies" USING "btree" ("opportunity_id");



CREATE INDEX "idx_states_name_unaccent" ON "public"."states" USING "gin" ("public"."f_unaccent"("name") "public"."gin_trgm_ops");



CREATE INDEX "idx_student_applications_partner_id" ON "public"."student_applications" USING "btree" ("partner_id");



CREATE INDEX "idx_student_applications_status" ON "public"."student_applications" USING "btree" ("status");



CREATE INDEX "idx_student_applications_user_id" ON "public"."student_applications" USING "btree" ("user_id");



CREATE INDEX "idx_uom_profile" ON "public"."user_opportunity_matches" USING "btree" ("profile_id");



CREATE INDEX "idx_uom_profile_generated" ON "public"."user_opportunity_matches" USING "btree" ("profile_id", "generated_at" DESC);



CREATE INDEX "idx_uom_score" ON "public"."user_opportunity_matches" USING "btree" ("match_score" DESC);



CREATE INDEX "idx_user_enem_scores_user_id" ON "public"."user_enem_scores" USING "btree" ("user_id");



CREATE INDEX "idx_user_favorites_course_id" ON "public"."user_favorites" USING "btree" ("course_id");



CREATE INDEX "idx_user_favorites_partner_id" ON "public"."user_favorites" USING "btree" ("partner_opportunities_id");



CREATE INDEX "idx_user_favorites_user_id" ON "public"."user_favorites" USING "btree" ("user_id");



CREATE INDEX "idx_user_permissions_permission" ON "public"."user_permissions" USING "btree" ("permission");



CREATE INDEX "idx_user_preferences_user_id" ON "public"."user_preferences" USING "btree" ("user_id");



CREATE INDEX "idx_user_profiles_id" ON "public"."user_profiles" USING "btree" ("id");



CREATE INDEX "idx_users_metadata_profile_id" ON "public"."users_metadata" USING "btree" ("profile_id");



CREATE INDEX "idx_v_unified_opportunities_institution" ON "public"."v_unified_opportunities" USING "btree" ("institution_id");



CREATE INDEX "idx_v_unified_opportunities_search_text" ON "public"."v_unified_opportunities" USING "gin" ("search_text" "public"."gin_trgm_ops");



CREATE INDEX "partner_solicitation_attempts_ip_time_idx" ON "public"."partner_solicitation_attempts" USING "btree" ("ip_hash", "created_at" DESC);



CREATE INDEX "partner_solicitation_attempts_time_idx" ON "public"."partner_solicitation_attempts" USING "btree" ("created_at" DESC);



CREATE INDEX "rawsisu_CO_IES_NO_CAMPUS_NO_MUNICIPIO_CAMPUS_CO_IES_CURSO_D_idx" ON "public"."rawsisu" USING "btree" ("CO_IES", "NO_CAMPUS", "NO_MUNICIPIO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA");



CREATE INDEX "rawsisuvacancies_CO_IES_NO_CAMPUS_NO_MUNICIPIO_CAMPUS_CO_IE_idx" ON "public"."rawsisuvacancies" USING "btree" ("CO_IES", "NO_CAMPUS", "NO_MUNICIPIO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA");



CREATE INDEX "rawsisuvacancies_CO_IES_idx" ON "public"."rawsisuvacancies" USING "btree" ("CO_IES");



CREATE INDEX "rawsisuvacancies_NO_CAMPUS_idx" ON "public"."rawsisuvacancies" USING "btree" ("NO_CAMPUS");



CREATE INDEX "rawsisuvacancies_NO_MUNICIPIO_CAMPUS_idx" ON "public"."rawsisuvacancies" USING "btree" ("NO_MUNICIPIO_CAMPUS");



CREATE UNIQUE INDEX "uq_etl_run_logs_one_running" ON "public"."etl_run_logs" USING "btree" ("program_id", "etl_type") WHERE (("status" = 'running'::"text") AND ("program_id" IS NOT NULL));



CREATE UNIQUE INDEX "uq_v_unified_opportunities_id_type" ON "public"."v_unified_opportunities" USING "btree" ("unified_id", "type");



CREATE OR REPLACE TRIGGER "before_campus_insert_update_coordinates" BEFORE INSERT OR UPDATE ON "public"."campus" FOR EACH ROW EXECUTE FUNCTION "public"."trg_populate_campus_coordinates"();



CREATE OR REPLACE TRIGGER "before_insert_user_profiles_check_nubo" BEFORE INSERT ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."check_nubo_student_eligibility"();



CREATE OR REPLACE TRIGGER "etl_run_logs_timestamps_trigger" BEFORE INSERT OR UPDATE ON "public"."etl_run_logs" FOR EACH ROW EXECUTE FUNCTION "public"."trg_etl_run_logs_timestamps"();



CREATE OR REPLACE TRIGGER "on_score_change" AFTER INSERT OR UPDATE ON "public"."user_enem_scores" FOR EACH ROW EXECUTE FUNCTION "public"."update_best_enem_score"();



CREATE OR REPLACE TRIGGER "on_student_application_eligibility" AFTER INSERT OR UPDATE ON "public"."student_applications" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_calculate_passport_eligibility"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trg_snapshot_agent_prompt_version" BEFORE UPDATE ON "public"."agent_prompts" FOR EACH ROW EXECUTE FUNCTION "public"."snapshot_agent_prompt_version"();



CREATE OR REPLACE TRIGGER "trigger_ensure_single_active_program" AFTER INSERT OR UPDATE OF "status" ON "public"."programs" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_single_active_program"();



CREATE OR REPLACE TRIGGER "update_furthest_passport_phase_trg" BEFORE UPDATE OF "passport_phase", "furthest_passport_phase" ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."trg_update_furthest_passport_phase"();



CREATE OR REPLACE TRIGGER "update_partner_forms_updated_at" BEFORE UPDATE ON "public"."partner_forms" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_partners_click_updated_at" BEFORE UPDATE ON "public"."partners_click" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_partners_updated_at" BEFORE UPDATE ON "public"."partners" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_student_applications_updated_at" BEFORE UPDATE ON "public"."student_applications" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."admin_alerts"
    ADD CONSTRAINT "admin_alerts_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_errors"
    ADD CONSTRAINT "agent_errors_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_errors"
    ADD CONSTRAINT "agent_errors_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_feedback"
    ADD CONSTRAINT "agent_feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_prompt_versions"
    ADD CONSTRAINT "agent_prompt_versions_agent_prompt_id_fkey" FOREIGN KEY ("agent_prompt_id") REFERENCES "public"."agent_prompts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_prompts"
    ADD CONSTRAINT "agent_prompts_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_turns"
    ADD CONSTRAINT "agent_turns_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."campus"
    ADD CONSTRAINT "campus_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."channel_links"
    ADD CONSTRAINT "channel_links_campaign_id_fkey" FOREIGN KEY ("campaign_id") REFERENCES "public"."campaigns"("id");



ALTER TABLE ONLY "public"."channel_links"
    ADD CONSTRAINT "channel_links_channel_id_fkey" FOREIGN KEY ("channel_id") REFERENCES "public"."channels"("id");



ALTER TABLE ONLY "public"."channel_links"
    ADD CONSTRAINT "channel_links_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("slug");



ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_type_fkey" FOREIGN KEY ("type") REFERENCES "public"."channel_mediums"("slug");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."conversions"
    ADD CONSTRAINT "conversions_channel_link_id_fkey" FOREIGN KEY ("channel_link_id") REFERENCES "public"."channel_links"("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_campus_id_fkey" FOREIGN KEY ("campus_id") REFERENCES "public"."campus"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."engagement_events"
    ADD CONSTRAINT "engagement_events_channel_link_fk" FOREIGN KEY ("channel_link_id") REFERENCES "public"."channel_links"("id");



ALTER TABLE ONLY "public"."etl_run_logs"
    ADD CONSTRAINT "etl_run_logs_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("id");



ALTER TABLE ONLY "public"."etl_run_logs"
    ADD CONSTRAINT "etl_run_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."external_redirect_clicks"
    ADD CONSTRAINT "external_redirect_clicks_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id");



ALTER TABLE ONLY "public"."external_redirect_clicks"
    ADD CONSTRAINT "external_redirect_clicks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."important_dates"
    ADD CONSTRAINT "important_dates_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."important_dates"
    ADD CONSTRAINT "important_dates_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."institutions_info_emec"
    ADD CONSTRAINT "institutionsinfoemec_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."institutions_info_sisu"
    ADD CONSTRAINT "institutionsinfosisu_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_document_opportunities"
    ADD CONSTRAINT "knowledge_document_opportunities_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."knowledge_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_document_opportunities"
    ADD CONSTRAINT "knowledge_document_opportunities_partner_opportunity_id_fkey" FOREIGN KEY ("partner_opportunity_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_document_versions"
    ADD CONSTRAINT "knowledge_document_versions_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."knowledge_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_documents"
    ADD CONSTRAINT "knowledge_documents_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."knowledge_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."knowledge_documents"
    ADD CONSTRAINT "knowledge_documents_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."knowledge_keywords"
    ADD CONSTRAINT "knowledge_keywords_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."knowledge_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."opportunities"
    ADD CONSTRAINT "opportunities_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."opportunities_prouni_vacancies"
    ADD CONSTRAINT "opportunities_prouni_vacancies_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."opportunities_sisu_vacancies"
    ADD CONSTRAINT "opportunitiessisuvacancies_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."opportunity_phases"
    ADD CONSTRAINT "opportunity_phases_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_step_id_fkey" FOREIGN KEY ("step_id") REFERENCES "public"."partner_steps"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partner_institutions"
    ADD CONSTRAINT "partner_institutions_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_opportunities"
    ADD CONSTRAINT "partner_opportunities_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."partner_steps"
    ADD CONSTRAINT "partner_steps_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partners_click"
    ADD CONSTRAINT "partners_click_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id");



ALTER TABLE ONLY "public"."partners_click"
    ADD CONSTRAINT "partners_click_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."partners_users"
    ADD CONSTRAINT "partners_users_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_institutions"("institution_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partners_users"
    ADD CONSTRAINT "partners_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_prev_program_id_fkey" FOREIGN KEY ("prev_program_id") REFERENCES "public"."programs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sean_ellis_score"
    ADD CONSTRAINT "sean_ellis_score_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_phase_id_fkey" FOREIGN KEY ("phase_id") REFERENCES "public"."opportunity_phases"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_attribution"
    ADD CONSTRAINT "user_attribution_first_touch_link_id_fkey" FOREIGN KEY ("first_touch_link_id") REFERENCES "public"."channel_links"("id");



ALTER TABLE ONLY "public"."user_attribution"
    ADD CONSTRAINT "user_attribution_last_touch_link_id_fkey" FOREIGN KEY ("last_touch_link_id") REFERENCES "public"."channel_links"("id");



ALTER TABLE ONLY "public"."user_enem_scores"
    ADD CONSTRAINT "user_enem_scores_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_partner_opportunities_id_fkey" FOREIGN KEY ("partner_opportunities_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_income"
    ADD CONSTRAINT "user_income_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_opportunity_matches"
    ADD CONSTRAINT "user_opportunity_matches_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_active_application_target_id_fkey" FOREIGN KEY ("active_application_target_id") REFERENCES "public"."user_profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_current_dependent_id_fkey" FOREIGN KEY ("current_dependent_id") REFERENCES "public"."user_profiles"("id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_parent_user_id_fkey" FOREIGN KEY ("parent_user_id") REFERENCES "public"."user_profiles"("id");



ALTER TABLE ONLY "public"."user_rate_limits"
    ADD CONSTRAINT "user_rate_limits_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users_metadata"
    ADD CONSTRAINT "users_metadata_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can delete partners" ON "public"."partners" FOR DELETE TO "authenticated" USING ("public"."has_permission"('Parceiros'::"text"));



CREATE POLICY "Admins can insert partners" ON "public"."partners" FOR INSERT TO "authenticated" WITH CHECK ("public"."has_permission"('Parceiros'::"text"));



CREATE POLICY "Admins can manage influencers" ON "public"."influencers" TO "authenticated" USING ("public"."has_permission"('Influencers'::"text")) WITH CHECK ("public"."has_permission"('Influencers'::"text"));



CREATE POLICY "Admins can update partners" ON "public"."partners" FOR UPDATE TO "authenticated" USING ("public"."has_permission"('Parceiros'::"text")) WITH CHECK ("public"."has_permission"('Parceiros'::"text"));



CREATE POLICY "Admins can view all clicks" ON "public"."partners_click" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Dashboard'::"text")))));



CREATE POLICY "Admins can view all enem scores" ON "public"."user_enem_scores" FOR SELECT TO "authenticated" USING ("public"."has_permission"('Estudantes'::"text"));



CREATE POLICY "Admins can view all favorites" ON "public"."user_favorites" FOR SELECT TO "authenticated" USING ("public"."has_permission"('Estudantes'::"text"));



CREATE POLICY "Admins can view all preferences" ON "public"."user_preferences" FOR SELECT TO "authenticated" USING ("public"."has_permission"('Estudantes'::"text"));



CREATE POLICY "Admins can view all profiles" ON "public"."user_profiles" FOR SELECT TO "authenticated" USING ("public"."has_permission"('Estudantes'::"text"));



CREATE POLICY "Admins can view all solicitations" ON "public"."partner_solicitations" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Dashboard'::"text")))));



CREATE POLICY "Admins can view chat messages" ON "public"."chat_messages" FOR SELECT TO "authenticated" USING ("public"."has_permission"('Conversas'::"text"));



CREATE POLICY "Admins can view errors" ON "public"."agent_errors" FOR SELECT TO "authenticated" USING ("public"."has_permission"('Erros'::"text"));



CREATE POLICY "Admins can view partners" ON "public"."partners" FOR SELECT TO "authenticated" USING (("public"."has_permission"('Parceiros'::"text") OR "public"."has_permission"('Estudantes'::"text")));



CREATE POLICY "Allow admins to manage permissions" ON "public"."user_permissions" TO "authenticated" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



CREATE POLICY "Allow authenticated delete" ON "public"."important_dates" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated insert" ON "public"."important_dates" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated update" ON "public"."important_dates" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Allow backoffice to view permissions" ON "public"."user_permissions" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR "public"."is_backoffice_admin"()));



CREATE POLICY "Allow full access to service_role" ON "public"."partner_solicitations" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow modify for users with Sean Ellis permission" ON "public"."sean_ellis_score" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Sean Ellis Score'::"text")))) OR "public"."is_backoffice_admin"())) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Sean Ellis Score'::"text")))) OR "public"."is_backoffice_admin"()));



CREATE POLICY "Allow public insert" ON "public"."ai_insights" FOR INSERT WITH CHECK (true);



CREATE POLICY "Allow public read access" ON "public"."ai_insights" FOR SELECT USING (true);



CREATE POLICY "Allow read for users with Sean Ellis permission" ON "public"."sean_ellis_score" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Sean Ellis Score'::"text")))) OR "public"."is_backoffice_admin"()));



CREATE POLICY "Anyone can view partner forms" ON "public"."partner_forms" FOR SELECT USING (true);



CREATE POLICY "Enable delete access for all authenticated users" ON "public"."partner_steps" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Enable insert access for all authenticated users" ON "public"."partner_steps" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable read access for all authenticated users" ON "public"."partner_steps" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."important_dates" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Enable update access for all authenticated users" ON "public"."partner_steps" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Everyone can read active examples" ON "public"."learning_examples" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Public can read campus" ON "public"."campus" FOR SELECT USING (true);



CREATE POLICY "Public can read cities" ON "public"."cities" FOR SELECT USING (true);



CREATE POLICY "Public can read courses" ON "public"."courses" FOR SELECT USING (true);



CREATE POLICY "Public can read important_dates" ON "public"."important_dates" FOR SELECT USING (true);



CREATE POLICY "Public can read institutions" ON "public"."institutions" FOR SELECT USING (true);



CREATE POLICY "Public can read institutionsinfoemec" ON "public"."institutions_info_emec" FOR SELECT USING (true);



CREATE POLICY "Public can read institutionsinfosisu" ON "public"."institutions_info_sisu" FOR SELECT USING (true);



CREATE POLICY "Public can read opportunities" ON "public"."opportunities" FOR SELECT USING (true);



CREATE POLICY "Public can read partners" ON "public"."partners" FOR SELECT USING (true);



CREATE POLICY "Public read access to active influencers" ON "public"."influencers" FOR SELECT USING (("active" = true));



CREATE POLICY "Service role can insert errors" ON "public"."agent_errors" FOR INSERT TO "authenticated", "service_role" WITH CHECK (true);



CREATE POLICY "Service role can manage learning examples" ON "public"."learning_examples" USING (true) WITH CHECK (true);



CREATE POLICY "Service role can view errors" ON "public"."agent_errors" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Service role has full access to user_income" ON "public"."user_income" USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "Users can delete own favorites" ON "public"."user_favorites" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own favorites" ON "public"."user_favorites" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own scores" ON "public"."user_enem_scores" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own applications" ON "public"."student_applications" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own clicks" ON "public"."partners_click" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own favorites" ON "public"."user_favorites" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own feedback" ON "public"."agent_feedback" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own messages" ON "public"."chat_messages" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own profile" ON "public"."user_profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert own rate limits" ON "public"."user_rate_limits" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own favorites" ON "public"."user_favorites" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own feedback" ON "public"."agent_feedback" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own income" ON "public"."user_income" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own preferences" ON "public"."user_preferences" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own redirect clicks" ON "public"."external_redirect_clicks" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own scores" ON "public"."user_enem_scores" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert/update their own partner clicks" ON "public"."partners_click" TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage their own favorites" ON "public"."user_favorites" USING ((("auth"."uid"() = "user_id") OR ("user_id" IN ( SELECT "user_profiles"."current_dependent_id"
   FROM "public"."user_profiles"
  WHERE ("user_profiles"."id" = "auth"."uid"())))));



CREATE POLICY "Users can read their own favorites" ON "public"."user_favorites" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read their own redirect clicks" ON "public"."external_redirect_clicks" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own applications" ON "public"."student_applications" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own clicks" ON "public"."partners_click" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own profile" ON "public"."user_profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own rate limits" ON "public"."user_rate_limits" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own income" ON "public"."user_income" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own preferences" ON "public"."user_preferences" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own scores" ON "public"."user_enem_scores" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view dependent profiles" ON "public"."user_profiles" FOR SELECT USING (("auth"."uid"() = "parent_user_id"));



CREATE POLICY "Users can view own applications" ON "public"."student_applications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own clicks" ON "public"."partners_click" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own favorites" ON "public"."user_favorites" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own feedback" ON "public"."agent_feedback" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own messages" ON "public"."chat_messages" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own profile" ON "public"."user_profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own rate limits" ON "public"."user_rate_limits" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own feedback" ON "public"."agent_feedback" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own income" ON "public"."user_income" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own preferences" ON "public"."user_preferences" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own scores" ON "public"."user_enem_scores" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."admin_alerts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_alerts_insert_backoffice" ON "public"."admin_alerts" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_backoffice_admin"());



CREATE POLICY "admin_alerts_select_backoffice" ON "public"."admin_alerts" FOR SELECT TO "authenticated" USING ("public"."is_backoffice_admin"());



CREATE POLICY "admin_alerts_update_backoffice" ON "public"."admin_alerts" FOR UPDATE TO "authenticated" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



ALTER TABLE "public"."agent_errors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_feedback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_prompt_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "agent_prompt_versions_select_authenticated" ON "public"."agent_prompt_versions" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."agent_prompts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "agent_prompts_admin_all" ON "public"."agent_prompts" USING ("public"."is_backoffice_admin"());



CREATE POLICY "agent_prompts_select_all" ON "public"."agent_prompts" FOR SELECT USING (true);



ALTER TABLE "public"."agent_turns" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "agent_turns_admin_select" ON "public"."agent_turns" FOR SELECT USING ("public"."is_backoffice_admin"());



CREATE POLICY "agent_turns_insert_service" ON "public"."agent_turns" FOR INSERT WITH CHECK (true);



ALTER TABLE "public"."ai_insights" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."campaigns" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "campaigns_admin_all" ON "public"."campaigns" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



ALTER TABLE "public"."campus" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."channel_links" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "channel_links_admin_all" ON "public"."channel_links" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



ALTER TABLE "public"."channels" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "channels_admin_all" ON "public"."channels" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



ALTER TABLE "public"."chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cloudinha_starters" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cloudinha_starters_admin_all" ON "public"."cloudinha_starters" USING ("public"."is_backoffice_admin"());



CREATE POLICY "cloudinha_starters_select_all" ON "public"."cloudinha_starters" FOR SELECT USING (true);



ALTER TABLE "public"."conversions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "conversions_admin_all" ON "public"."conversions" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



ALTER TABLE "public"."courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."engagement_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "engagement_events_admin_read" ON "public"."engagement_events" FOR SELECT USING ("public"."is_backoffice_admin"());



CREATE POLICY "engagement_events_self_insert" ON "public"."engagement_events" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."external_redirect_clicks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_sections" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "home_sections_delete_authenticated" ON "public"."home_sections" FOR DELETE USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "home_sections_insert_authenticated" ON "public"."home_sections" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "home_sections_read_all" ON "public"."home_sections" FOR SELECT USING (true);



CREATE POLICY "home_sections_update_authenticated" ON "public"."home_sections" FOR UPDATE USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."important_dates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."influencers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."institutions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."institutions_info_emec" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."institutions_info_sisu" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."knowledge_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_categories_read" ON "public"."knowledge_categories" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."knowledge_document_opportunities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_document_opportunities_admin_manage" ON "public"."knowledge_document_opportunities" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Conhecimento'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Conhecimento'::"text")))));



CREATE POLICY "knowledge_document_opportunities_select_public" ON "public"."knowledge_document_opportunities" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."knowledge_documents" "kd"
  WHERE (("kd"."id" = "knowledge_document_opportunities"."document_id") AND ("kd"."is_active" = true)))) AND (EXISTS ( SELECT 1
   FROM "public"."partner_opportunities" "po"
  WHERE (("po"."id" = "knowledge_document_opportunities"."partner_opportunity_id") AND (("po"."status")::"text" = 'approved'::"text"))))));



ALTER TABLE "public"."knowledge_document_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_document_versions_read" ON "public"."knowledge_document_versions" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."knowledge_documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_documents_read" ON "public"."knowledge_documents" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."knowledge_keywords" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_keywords_read" ON "public"."knowledge_keywords" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."learning_examples" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."match_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "match_config_admin_all" ON "public"."match_config" USING ("public"."is_backoffice_admin"());



CREATE POLICY "match_config_select_all" ON "public"."match_config" FOR SELECT USING (true);



ALTER TABLE "public"."moderation_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."opportunities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."opportunity_phases" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "opportunity_phases_admin_manage" ON "public"."opportunity_phases" TO "authenticated" USING (("public"."is_backoffice_admin"() OR ("opportunity_id" IN ( SELECT "partner_opportunities"."id"
   FROM "public"."partner_opportunities"
  WHERE ("partner_opportunities"."institution_id" = "public"."get_my_partner_id"()))))) WITH CHECK (("public"."is_backoffice_admin"() OR ("opportunity_id" IN ( SELECT "partner_opportunities"."id"
   FROM "public"."partner_opportunities"
  WHERE ("partner_opportunities"."institution_id" = "public"."get_my_partner_id"())))));



CREATE POLICY "opportunity_phases_select_authenticated" ON "public"."opportunity_phases" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."partner_forms" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "partner_forms_admin_all" ON "public"."partner_forms" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Parceiros'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Parceiros'::"text")))));



CREATE POLICY "partner_forms_delete_admin" ON "public"."partner_forms" FOR DELETE TO "authenticated" USING ((("auth"."jwt"() ->> 'role'::"text") <> 'partner'::"text"));



CREATE POLICY "partner_forms_insert_admin" ON "public"."partner_forms" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") <> 'partner'::"text"));



CREATE POLICY "partner_forms_select_authenticated" ON "public"."partner_forms" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "partner_forms_update_admin" ON "public"."partner_forms" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'role'::"text") <> 'partner'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") <> 'partner'::"text"));



ALTER TABLE "public"."partner_institutions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "partner_institutions_admin_manage" ON "public"."partner_institutions" TO "authenticated" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



CREATE POLICY "partner_institutions_select_all" ON "public"."partner_institutions" FOR SELECT USING (true);



CREATE POLICY "partner_opp_admin_manage" ON "public"."partner_opportunities" TO "authenticated" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



CREATE POLICY "partner_opp_select_visible" ON "public"."partner_opportunities" FOR SELECT USING (((("status")::"text" = ANY ((ARRAY['incoming'::character varying, 'opened'::character varying, 'closed'::character varying])::"text"[])) OR "public"."is_backoffice_admin"()));



ALTER TABLE "public"."partner_opportunities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partner_solicitation_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partner_solicitations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partner_steps" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partners_click" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partners_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "partners_users_admin_all" ON "public"."partners_users" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Parceiros'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_permissions"
  WHERE (("user_permissions"."user_id" = "auth"."uid"()) AND ("user_permissions"."permission" = 'Parceiros'::"text")))));



CREATE POLICY "partners_users_select_own" ON "public"."partners_users" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."programs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "programs_admin_all" ON "public"."programs" USING ("public"."is_backoffice_admin"());



CREATE POLICY "programs_select_all" ON "public"."programs" FOR SELECT USING (true);



ALTER TABLE "public"."rawsisu" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rawsisu_service_all" ON "public"."rawsisu" USING (true);



CREATE POLICY "redirect_clicks_admin_read" ON "public"."external_redirect_clicks" FOR SELECT TO "authenticated" USING ("public"."is_backoffice_admin"());



CREATE POLICY "redirect_clicks_insert_own" ON "public"."external_redirect_clicks" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."sean_ellis_score" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_applications_admin_update" ON "public"."student_applications" FOR UPDATE USING ("public"."is_backoffice_admin"());



CREATE POLICY "student_applications_insert_own" ON "public"."student_applications" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "student_applications_partner_update" ON "public"."student_applications" FOR UPDATE USING (("partner_id" IN ( SELECT "po"."id"
   FROM ("public"."partner_opportunities" "po"
     JOIN "public"."partners_users" "pu" ON (("pu"."partner_id" = "po"."institution_id")))
  WHERE ("pu"."user_id" = "auth"."uid"()))));



CREATE POLICY "student_applications_select_admin" ON "public"."student_applications" FOR SELECT USING ("public"."is_backoffice_admin"());



CREATE POLICY "student_applications_select_own" ON "public"."student_applications" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "student_applications_select_partner" ON "public"."student_applications" FOR SELECT USING (("partner_id" IN ( SELECT "po"."id"
   FROM ("public"."partner_opportunities" "po"
     JOIN "public"."partners_users" "pu" ON (("pu"."partner_id" = "po"."institution_id")))
  WHERE ("pu"."user_id" = "auth"."uid"()))));



CREATE POLICY "student_applications_update_own" ON "public"."student_applications" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."system_intents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "system_intents_admin_all" ON "public"."system_intents" USING ("public"."is_backoffice_admin"());



CREATE POLICY "system_intents_select_all" ON "public"."system_intents" FOR SELECT USING (true);



CREATE POLICY "uom_delete_own" ON "public"."user_opportunity_matches" FOR DELETE USING (("profile_id" IN ( SELECT "user_profiles"."id"
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = "auth"."uid"()) OR ("user_profiles"."parent_user_id" = "auth"."uid"())))));



CREATE POLICY "uom_insert_own" ON "public"."user_opportunity_matches" FOR INSERT WITH CHECK (("profile_id" IN ( SELECT "user_profiles"."id"
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = "auth"."uid"()) OR ("user_profiles"."parent_user_id" = "auth"."uid"())))));



CREATE POLICY "uom_select_own" ON "public"."user_opportunity_matches" FOR SELECT USING (("profile_id" IN ( SELECT "user_profiles"."id"
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = "auth"."uid"()) OR ("user_profiles"."parent_user_id" = "auth"."uid"())))));



ALTER TABLE "public"."user_attribution" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_attribution_admin_all" ON "public"."user_attribution" USING ("public"."is_backoffice_admin"()) WITH CHECK ("public"."is_backoffice_admin"());



ALTER TABLE "public"."user_enem_scores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_income" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_opportunity_matches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_rate_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users_metadata" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_metadata_insert_own" ON "public"."users_metadata" FOR INSERT WITH CHECK (("profile_id" IN ( SELECT "user_profiles"."id"
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = "auth"."uid"()) OR ("user_profiles"."parent_user_id" = "auth"."uid"())))));



CREATE POLICY "users_metadata_select_own" ON "public"."users_metadata" FOR SELECT USING (("profile_id" IN ( SELECT "user_profiles"."id"
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = "auth"."uid"()) OR ("user_profiles"."parent_user_id" = "auth"."uid"())))));



CREATE POLICY "users_metadata_update_own" ON "public"."users_metadata" FOR UPDATE USING (("profile_id" IN ( SELECT "user_profiles"."id"
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = "auth"."uid"()) OR ("user_profiles"."parent_user_id" = "auth"."uid"())))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "partner";






GRANT ALL ON FUNCTION "public"."cube_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_out"("public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_out"("public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_out"("public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_out"("public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_recv"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_recv"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_recv"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_recv"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_send"("public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_send"("public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_send"("public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_send"("public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";











































































































































































GRANT ALL ON FUNCTION "public"."_eligib_eval_leaf"("p_val_text" "text", "p_val_num" numeric, "p_leaf" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."_eligib_eval_leaf"("p_val_text" "text", "p_val_num" numeric, "p_leaf" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_eligib_eval_leaf"("p_val_text" "text", "p_val_num" numeric, "p_leaf" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."_eligib_to_num"("p_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_eligib_to_num"("p_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_eligib_to_num"("p_text" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text", "p_last_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text", "p_last_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text", "p_last_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."attach_user_attribution"("p_user_id" "uuid", "p_anonymous_id" "text", "p_first_code" "text", "p_last_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."backfill_eligibility_and_mappings"() TO "anon";
GRANT ALL ON FUNCTION "public"."backfill_eligibility_and_mappings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."backfill_eligibility_and_mappings"() TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulk_import_important_dates"("p_dates" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_import_important_dates"("p_dates" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_import_important_dates"("p_dates" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."bulk_import_important_dates"("p_dates" "jsonb") TO "partner";



GRANT ALL ON FUNCTION "public"."calculate_application_eligibility"("p_application_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_application_eligibility"("p_application_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_application_eligibility"("p_application_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_match"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_match"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_match"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_match_async_worker"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_match_async_worker"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_match_async_worker"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_passport_eligibility"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_passport_eligibility"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_passport_eligibility"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_nubo_student_eligibility"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_nubo_student_eligibility"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_nubo_student_eligibility"() TO "service_role";
GRANT ALL ON FUNCTION "public"."check_nubo_student_eligibility"() TO "partner";



GRANT ALL ON FUNCTION "public"."clean_numeric_string"("val" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."clean_numeric_string"("val" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clean_numeric_string"("val" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."clean_numeric_string"("val" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."clean_phone_number"("input_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."clean_phone_number"("input_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clean_phone_number"("input_phone" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."clean_phone_number"("input_phone" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cron_check_deadlines"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cron_check_deadlines"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cube"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."cube"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube"(double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube"(double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."cube"(double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube"(double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."cube"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube"(double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube"(double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."cube"(double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube"(double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube"("public"."cube", double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_cmp"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_cmp"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_cmp"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_cmp"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_contained"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_contained"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_contained"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_contained"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_contains"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_contains"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_contains"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_contains"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_coord"("public"."cube", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_coord"("public"."cube", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cube_coord"("public"."cube", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_coord"("public"."cube", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_coord_llur"("public"."cube", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_coord_llur"("public"."cube", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cube_coord_llur"("public"."cube", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_coord_llur"("public"."cube", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_dim"("public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_dim"("public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_dim"("public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_dim"("public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_distance"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_distance"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_distance"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_distance"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_enlarge"("public"."cube", double precision, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_enlarge"("public"."cube", double precision, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cube_enlarge"("public"."cube", double precision, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_enlarge"("public"."cube", double precision, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_eq"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_eq"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_eq"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_eq"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_ge"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_ge"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_ge"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_ge"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_gt"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_gt"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_gt"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_gt"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_inter"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_inter"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_inter"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_inter"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_is_point"("public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_is_point"("public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_is_point"("public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_is_point"("public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_le"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_le"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_le"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_le"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_ll_coord"("public"."cube", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_ll_coord"("public"."cube", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cube_ll_coord"("public"."cube", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_ll_coord"("public"."cube", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_lt"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_lt"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_lt"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_lt"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_ne"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_ne"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_ne"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_ne"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_overlap"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_overlap"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_overlap"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_overlap"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_size"("public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_size"("public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_size"("public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_size"("public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_subset"("public"."cube", integer[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_subset"("public"."cube", integer[]) TO "anon";
GRANT ALL ON FUNCTION "public"."cube_subset"("public"."cube", integer[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_subset"("public"."cube", integer[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_union"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_union"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."cube_union"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_union"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."cube_ur_coord"("public"."cube", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."cube_ur_coord"("public"."cube", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cube_ur_coord"("public"."cube", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cube_ur_coord"("public"."cube", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."distance_chebyshev"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."distance_chebyshev"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."distance_chebyshev"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."distance_chebyshev"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."distance_taxicab"("public"."cube", "public"."cube") TO "postgres";
GRANT ALL ON FUNCTION "public"."distance_taxicab"("public"."cube", "public"."cube") TO "anon";
GRANT ALL ON FUNCTION "public"."distance_taxicab"("public"."cube", "public"."cube") TO "authenticated";
GRANT ALL ON FUNCTION "public"."distance_taxicab"("public"."cube", "public"."cube") TO "service_role";



GRANT ALL ON FUNCTION "public"."earth"() TO "postgres";
GRANT ALL ON FUNCTION "public"."earth"() TO "anon";
GRANT ALL ON FUNCTION "public"."earth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."earth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."gc_to_sec"(double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."gc_to_sec"(double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."gc_to_sec"(double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."gc_to_sec"(double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."earth_box"("public"."earth", double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."earth_box"("public"."earth", double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."earth_box"("public"."earth", double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."earth_box"("public"."earth", double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."sec_to_gc"(double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."sec_to_gc"(double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."sec_to_gc"(double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sec_to_gc"(double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."earth_distance"("public"."earth", "public"."earth") TO "postgres";
GRANT ALL ON FUNCTION "public"."earth_distance"("public"."earth", "public"."earth") TO "anon";
GRANT ALL ON FUNCTION "public"."earth_distance"("public"."earth", "public"."earth") TO "authenticated";
GRANT ALL ON FUNCTION "public"."earth_distance"("public"."earth", "public"."earth") TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_single_active_program"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_single_active_program"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_single_active_program"() TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_clone_prouni_cycle"("p_source_program_id" "uuid", "p_target_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_clone_prouni_cycle"("p_source_program_id" "uuid", "p_target_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_clone_prouni_cycle"("p_source_program_id" "uuid", "p_target_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_emec"() TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_emec"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_emec"() TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_emec"("p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_emec"("p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_emec"("p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_prouni"("p_program_id" "uuid", "p_limit" integer, "p_after_ctid" "text", "p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_prouni"("p_program_id" "uuid", "p_limit" integer, "p_after_ctid" "text", "p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_prouni"("p_program_id" "uuid", "p_limit" integer, "p_after_ctid" "text", "p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_refresh_opportunities"() TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_refresh_opportunities"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_refresh_opportunities"() TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_sisu"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_import_sisu_vacancies"("p_program_id" "uuid", "p_limit" integer, "p_offset" integer, "p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_reap_stale_runs"("p_max_age" interval) TO "anon";
GRANT ALL ON FUNCTION "public"."etl_reap_stale_runs"("p_max_age" interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_reap_stale_runs"("p_max_age" interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_rollback_log"("p_log_id" "uuid", "p_limit" integer, "p_active_rollback_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_rollback_log"("p_log_id" "uuid", "p_limit" integer, "p_active_rollback_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_rollback_log"("p_log_id" "uuid", "p_limit" integer, "p_active_rollback_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."etl_stop_log"("p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."etl_stop_log"("p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."etl_stop_log"("p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."evaluate_partner_eligibility"("p_profile_id" "uuid", "p_partner_opportunity_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."evaluate_partner_eligibility"("p_profile_id" "uuid", "p_partner_opportunity_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluate_partner_eligibility"("p_profile_id" "uuid", "p_partner_opportunity_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."execute_readonly_query"("query_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."execute_readonly_query"("query_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."execute_readonly_query"("query_text" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."f_parse_ptbr_numeric"("p_val" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."f_parse_ptbr_numeric"("p_val" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."f_parse_ptbr_numeric"("p_val" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."f_unaccent"("p_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."f_unaccent"("p_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."f_unaccent"("p_text" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."f_unaccent"("p_text" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."g_cube_consistent"("internal", "public"."cube", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."g_cube_consistent"("internal", "public"."cube", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."g_cube_consistent"("internal", "public"."cube", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."g_cube_consistent"("internal", "public"."cube", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."g_cube_distance"("internal", "public"."cube", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."g_cube_distance"("internal", "public"."cube", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."g_cube_distance"("internal", "public"."cube", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."g_cube_distance"("internal", "public"."cube", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."g_cube_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."g_cube_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."g_cube_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."g_cube_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."g_cube_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."g_cube_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."g_cube_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."g_cube_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."g_cube_same"("public"."cube", "public"."cube", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."g_cube_same"("public"."cube", "public"."cube", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."g_cube_same"("public"."cube", "public"."cube", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."g_cube_same"("public"."cube", "public"."cube", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."g_cube_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."g_cube_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."g_cube_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."g_cube_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."geo_distance"("point", "point") TO "postgres";
GRANT ALL ON FUNCTION "public"."geo_distance"("point", "point") TO "anon";
GRANT ALL ON FUNCTION "public"."geo_distance"("point", "point") TO "authenticated";
GRANT ALL ON FUNCTION "public"."geo_distance"("point", "point") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_applications_over_time"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_applications_over_time"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_applications_over_time"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_applications_over_time"("p_partner_id" "uuid", "p_days_ago" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_applications_over_time"("p_partner_id" "uuid", "p_days_ago" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_applications_over_time"("p_partner_id" "uuid", "p_days_ago" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_course_opportunities"("p_course_id" "uuid", "p_year" integer, "p_opportunity_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_course_opportunities"("p_course_id" "uuid", "p_year" integer, "p_opportunity_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_course_opportunities"("p_course_id" "uuid", "p_year" integer, "p_opportunity_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_educational_campus_options"("p_institution_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_educational_campus_options"("p_institution_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_educational_campus_options"("p_institution_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_educational_courses"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_institution_id" "uuid", "p_campus_id" "uuid", "p_degree" "text", "p_year" integer, "p_opportunity_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_educational_courses"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_institution_id" "uuid", "p_campus_id" "uuid", "p_degree" "text", "p_year" integer, "p_opportunity_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_educational_courses"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_institution_id" "uuid", "p_campus_id" "uuid", "p_degree" "text", "p_year" integer, "p_opportunity_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_educational_filter_options"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_educational_filter_options"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_educational_filter_options"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_educational_institutions"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_state" "text", "p_source" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_educational_institutions"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_state" "text", "p_source" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_educational_institutions"("p_page" integer, "p_page_size" integer, "p_search" "text", "p_state" "text", "p_source" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_funnel_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_funnel_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_funnel_users"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_institution_campuses"("p_institution_id" "uuid", "p_page" integer, "p_page_size" integer, "p_search" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_institution_campuses"("p_institution_id" "uuid", "p_page" integer, "p_page_size" integer, "p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_institution_campuses"("p_institution_id" "uuid", "p_page" integer, "p_page_size" integer, "p_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "partner";



REVOKE ALL ON FUNCTION "public"."get_channel_performance"("p_since" "date", "p_until" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_channel_performance"("p_since" "date", "p_until" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_channel_performance"("p_since" "date", "p_until" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "partner";



REVOKE ALL ON FUNCTION "public"."get_command_center_demographics"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_command_center_demographics"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_command_center_demographics"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "partner";



GRANT ALL ON FUNCTION "public"."get_eligible_count_by_institution"("p_institution_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_eligible_count_by_institution"("p_institution_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_eligible_count_by_institution"("p_institution_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_eligible_count_for_partner"("p_partner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_eligible_count_for_partner"("p_partner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_eligible_count_for_partner"("p_partner_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_influencer_affiliates"("influencer_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_influencer_affiliates"("influencer_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_influencer_affiliates"("influencer_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_influencer_affiliates"("influencer_code" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."get_influencer_dashboard_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_influencer_dashboard_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_influencer_dashboard_stats"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_influencer_dashboard_stats"() TO "partner";



GRANT ALL ON FUNCTION "public"."get_influencer_stats"("p_sort_by" "text", "p_sort_order" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_influencer_stats"("p_sort_by" "text", "p_sort_order" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_influencer_stats"("p_sort_by" "text", "p_sort_order" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_influencer_stats"("p_sort_by" "text", "p_sort_order" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."get_knowledge_documents"("p_category_id" "uuid", "p_partner_id" "uuid", "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_knowledge_documents"("p_category_id" "uuid", "p_partner_id" "uuid", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_knowledge_documents"("p_category_id" "uuid", "p_partner_id" "uuid", "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_partner_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_partner_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_partner_id"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_my_partner_id"() TO "partner";



GRANT ALL ON FUNCTION "public"."get_opportunities_for_user"("p_profile_id" "uuid", "p_page" integer, "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_opportunities_for_user"("p_profile_id" "uuid", "p_page" integer, "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_opportunities_for_user"("p_profile_id" "uuid", "p_page" integer, "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "partner";



GRANT ALL ON FUNCTION "public"."get_partner_applications_by_institution"("p_institution_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_applications_by_institution"("p_institution_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_applications_by_institution"("p_institution_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_redirect_users"("p_partner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_redirect_users"("p_partner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_redirect_users"("p_partner_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_users"("p_partner_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_users"("p_partner_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_users"("p_partner_id" "text") TO "service_role";



GRANT ALL ON TABLE "public"."partners" TO "anon";
GRANT ALL ON TABLE "public"."partners" TO "authenticated";
GRANT ALL ON TABLE "public"."partners" TO "service_role";
GRANT ALL ON TABLE "public"."partners" TO "partner";



GRANT ALL ON FUNCTION "public"."get_partners"("p_sort_by" "text", "p_sort_order" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partners"("p_sort_by" "text", "p_sort_order" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partners"("p_sort_by" "text", "p_sort_order" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_passport_phase_weight"("phase" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_passport_phase_weight"("phase" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_passport_phase_weight"("phase" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "partner";



GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_data"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."get_sean_ellis_stats"("p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_stats"("p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_stats"("p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_sean_ellis_stats"("p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[]) TO "partner";



GRANT ALL ON FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_student_clicks_admin"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_student_clicks_admin"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_clicks_admin"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_student_matches_admin"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_matches_admin"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_matches_admin"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "partner";



REVOKE ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_unified_opportunities_by_distance"("p_lat" double precision, "p_long" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."get_unified_opportunities_by_distance"("p_lat" double precision, "p_long" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_unified_opportunities_by_distance"("p_lat" double precision, "p_long" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_unique_course_names"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_unique_course_names"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_unique_course_names"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_unique_course_names"() TO "partner";



GRANT ALL ON FUNCTION "public"."get_user_favorites"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_favorites"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_favorites"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_user_favorites"() TO "partner";



GRANT ALL ON FUNCTION "public"."get_user_favorites_details"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_favorites_details"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_favorites_details"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_user_favorites_details"() TO "partner";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "service_role";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "partner";



GRANT ALL ON FUNCTION "public"."has_dashboard_permission"() TO "anon";
GRANT ALL ON FUNCTION "public"."has_dashboard_permission"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_dashboard_permission"() TO "service_role";
GRANT ALL ON FUNCTION "public"."has_dashboard_permission"() TO "partner";



GRANT ALL ON FUNCTION "public"."has_permission"("p_permission" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_permission"("p_permission" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_permission"("p_permission" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."has_permission"("p_permission" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."haversine_km"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."haversine_km"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."haversine_km"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."import_nubo_students"("students" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."import_nubo_students"("students" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_nubo_students"("students" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."import_nubo_students"("students" "jsonb") TO "partner";



GRANT ALL ON FUNCTION "public"."import_sean_ellis_data"("data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."import_sean_ellis_data"("data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_sean_ellis_data"("data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."import_sean_ellis_data"("data" "jsonb") TO "partner";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_backoffice_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_backoffice_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_backoffice_admin"() TO "service_role";
GRANT ALL ON FUNCTION "public"."is_backoffice_admin"() TO "partner";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."latitude"("public"."earth") TO "postgres";
GRANT ALL ON FUNCTION "public"."latitude"("public"."earth") TO "anon";
GRANT ALL ON FUNCTION "public"."latitude"("public"."earth") TO "authenticated";
GRANT ALL ON FUNCTION "public"."latitude"("public"."earth") TO "service_role";



GRANT ALL ON FUNCTION "public"."ll_to_earth"(double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."ll_to_earth"(double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."ll_to_earth"(double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ll_to_earth"(double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."longitude"("public"."earth") TO "postgres";
GRANT ALL ON FUNCTION "public"."longitude"("public"."earth") TO "anon";
GRANT ALL ON FUNCTION "public"."longitude"("public"."earth") TO "authenticated";
GRANT ALL ON FUNCTION "public"."longitude"("public"."earth") TO "service_role";



GRANT ALL ON TABLE "public"."important_dates" TO "anon";
GRANT ALL ON TABLE "public"."important_dates" TO "authenticated";
GRANT ALL ON TABLE "public"."important_dates" TO "service_role";
GRANT ALL ON TABLE "public"."important_dates" TO "partner";



GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean, "p_controls_opportunity_dates" boolean, "p_partner_id" "uuid", "p_opportunity_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean, "p_controls_opportunity_dates" boolean, "p_partner_id" "uuid", "p_opportunity_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean, "p_controls_opportunity_dates" boolean, "p_partner_id" "uuid", "p_opportunity_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean, "p_partner_opportunity_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean, "p_partner_opportunity_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean, "p_partner_opportunity_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean, "p_external_redirect_config" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean, "p_external_redirect_config" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_partner"("p_id" "uuid", "p_name" "text", "p_description" "text", "p_location" "text", "p_type" "text", "p_income" "text", "p_dates" "jsonb", "p_link" "text", "p_coverimage" "text", "p_applications_open" boolean, "p_delete" boolean, "p_external_redirect_config" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_threshold" double precision, "match_count" integer) TO "partner";



GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "page_number" integer, "page_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "page_number" integer, "page_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "page_number" integer, "page_size" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "course_interests" "text"[], "income_per_capita" numeric, "quota_types" "text"[], "preferred_shifts" "text"[], "program_preference" "text", "user_lat" double precision, "user_long" double precision, "city_names" "text"[], "page_size" integer, "page_number" integer, "state_names" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "course_interests" "text"[], "income_per_capita" numeric, "quota_types" "text"[], "preferred_shifts" "text"[], "program_preference" "text", "user_lat" double precision, "user_long" double precision, "city_names" "text"[], "page_size" integer, "page_number" integer, "state_names" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "course_interests" "text"[], "income_per_capita" numeric, "quota_types" "text"[], "preferred_shifts" "text"[], "program_preference" "text", "user_lat" double precision, "user_long" double precision, "city_names" "text"[], "page_size" integer, "page_number" integer, "state_names" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."match_opportunities"("p_user_id" "uuid", "course_interests" "text"[], "income_per_capita" numeric, "quota_types" "text"[], "preferred_shifts" "text"[], "program_preference" "text", "user_lat" double precision, "user_long" double precision, "city_names" "text"[], "page_size" integer, "page_number" integer, "state_names" "text"[]) TO "partner";



GRANT ALL ON FUNCTION "public"."normalize_whatsapp"("phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_whatsapp"("phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_whatsapp"("phone" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."normalize_whatsapp"("phone" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."pre_fill_application"("p_user_id" "uuid", "p_partner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."pre_fill_application"("p_user_id" "uuid", "p_partner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pre_fill_application"("p_user_id" "uuid", "p_partner_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_mec_campus_csv"("p_records" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."process_mec_campus_csv"("p_records" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_mec_campus_csv"("p_records" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_mec_courses_csv"("p_records" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."process_mec_courses_csv"("p_records" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_mec_courses_csv"("p_records" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_mec_institutions_csv"("p_records" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."process_mec_institutions_csv"("p_records" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_mec_institutions_csv"("p_records" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_unified_opportunity_id" "text", "p_source" "text", "p_anonymous_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_unified_opportunity_id" "text", "p_source" "text", "p_anonymous_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_unified_opportunity_id" "text", "p_source" "text", "p_anonymous_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_card_click"("p_event_id" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_unified_opportunity_id" "text", "p_source" "text", "p_anonymous_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_card_views"("p_views" "jsonb", "p_anonymous_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_unified_opportunities"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_unified_opportunities"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_unified_opportunities"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_channel_link"("p_code" "text", "p_anonymous_id" "text", "p_event_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") TO "service_role";



GRANT ALL ON TABLE "public"."campus" TO "anon";
GRANT ALL ON TABLE "public"."campus" TO "authenticated";
GRANT ALL ON TABLE "public"."campus" TO "service_role";
GRANT ALL ON TABLE "public"."campus" TO "partner";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";
GRANT ALL ON TABLE "public"."courses" TO "partner";



GRANT ALL ON TABLE "public"."institutions" TO "anon";
GRANT ALL ON TABLE "public"."institutions" TO "authenticated";
GRANT ALL ON TABLE "public"."institutions" TO "service_role";
GRANT ALL ON TABLE "public"."institutions" TO "partner";



GRANT ALL ON TABLE "public"."institutions_info_emec" TO "anon";
GRANT ALL ON TABLE "public"."institutions_info_emec" TO "authenticated";
GRANT ALL ON TABLE "public"."institutions_info_emec" TO "service_role";
GRANT ALL ON TABLE "public"."institutions_info_emec" TO "partner";



GRANT ALL ON TABLE "public"."institutions_info_sisu" TO "anon";
GRANT ALL ON TABLE "public"."institutions_info_sisu" TO "authenticated";
GRANT ALL ON TABLE "public"."institutions_info_sisu" TO "service_role";
GRANT ALL ON TABLE "public"."institutions_info_sisu" TO "partner";



GRANT ALL ON TABLE "public"."opportunities" TO "anon";
GRANT ALL ON TABLE "public"."opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunities" TO "service_role";
GRANT ALL ON TABLE "public"."opportunities" TO "partner";



GRANT ALL ON TABLE "public"."opportunities_prouni_vacancies" TO "anon";
GRANT ALL ON TABLE "public"."opportunities_prouni_vacancies" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunities_prouni_vacancies" TO "service_role";



GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "anon";
GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "service_role";
GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "partner";



GRANT ALL ON TABLE "public"."partner_institutions" TO "anon";
GRANT ALL ON TABLE "public"."partner_institutions" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_institutions" TO "service_role";



GRANT ALL ON TABLE "public"."partner_opportunities" TO "anon";
GRANT ALL ON TABLE "public"."partner_opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_opportunities" TO "service_role";



GRANT ALL ON TABLE "public"."programs" TO "anon";
GRANT ALL ON TABLE "public"."programs" TO "authenticated";
GRANT ALL ON TABLE "public"."programs" TO "service_role";



GRANT ALL ON TABLE "public"."v_unified_opportunities" TO "anon";
GRANT ALL ON TABLE "public"."v_unified_opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."v_unified_opportunities" TO "service_role";



GRANT ALL ON FUNCTION "public"."search_opportunities"("p_q" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_opportunities"("p_q" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_opportunities"("p_q" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_opportunities_by_distance"("p_lat" double precision, "p_long" double precision, "p_q" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_opportunities_by_distance"("p_lat" double precision, "p_long" double precision, "p_q" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_opportunities_by_distance"("p_lat" double precision, "p_long" double precision, "p_q" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_partner_role_and_link"("p_user_id" "uuid", "p_partner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."set_partner_role_and_link"("p_user_id" "uuid", "p_partner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_partner_role_and_link"("p_user_id" "uuid", "p_partner_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."set_partner_role_and_link"("p_user_id" "uuid", "p_partner_id" "uuid") TO "partner";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."snapshot_agent_prompt_version"() TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_agent_prompt_version"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_agent_prompt_version"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON PROCEDURE "public"."standardize_user_locations"() TO "anon";
GRANT ALL ON PROCEDURE "public"."standardize_user_locations"() TO "authenticated";
GRANT ALL ON PROCEDURE "public"."standardize_user_locations"() TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_application_v1"("p_application_id" "uuid", "p_answers" "jsonb", "p_final_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_application_v1"("p_application_id" "uuid", "p_answers" "jsonb", "p_final_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_application_v1"("p_application_id" "uuid", "p_answers" "jsonb", "p_final_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_application_v1"("p_application_id" "uuid", "p_answers" "jsonb", "p_final_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text", "p_email" "text", "p_goals" "text", "p_ip" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text", "p_email" "text", "p_goals" "text", "p_ip" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text", "p_email" "text", "p_goals" "text", "p_ip" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_partner_solicitation"("p_institution_name" "text", "p_contact_name" "text", "p_how_did_you_know" "text", "p_whatsapp" "text", "p_email" "text", "p_goals" "text", "p_ip" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") TO "partner";



GRANT ALL ON FUNCTION "public"."trg_etl_run_logs_timestamps"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_etl_run_logs_timestamps"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_etl_run_logs_timestamps"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_populate_campus_coordinates"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_populate_campus_coordinates"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_populate_campus_coordinates"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_update_furthest_passport_phase"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_update_furthest_passport_phase"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_update_furthest_passport_phase"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_calculate_passport_eligibility"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_calculate_passport_eligibility"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_calculate_passport_eligibility"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_match_calculation"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_match_calculation"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_match_calculation"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_best_enem_score"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_best_enem_score"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_best_enem_score"() TO "service_role";
GRANT ALL ON FUNCTION "public"."update_best_enem_score"() TO "partner";



GRANT ALL ON FUNCTION "public"."update_own_profile"("p_full_name" "text", "p_age" integer, "p_city" "text", "p_education" "text", "p_zip_code" "text", "p_state" "text", "p_street" "text", "p_street_number" "text", "p_complement" "text", "p_passport_phase" "text", "p_relationship" "text", "p_isdependent" boolean, "p_parent_user_id" "uuid", "p_current_dependent_id" "uuid", "p_target_user_id" "uuid", "p_education_year" "text", "p_birth_date" "date", "p_neighborhood" "text", "p_country" "text", "p_outside_brazil" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_own_profile"("p_full_name" "text", "p_age" integer, "p_city" "text", "p_education" "text", "p_zip_code" "text", "p_state" "text", "p_street" "text", "p_street_number" "text", "p_complement" "text", "p_passport_phase" "text", "p_relationship" "text", "p_isdependent" boolean, "p_parent_user_id" "uuid", "p_current_dependent_id" "uuid", "p_target_user_id" "uuid", "p_education_year" "text", "p_birth_date" "date", "p_neighborhood" "text", "p_country" "text", "p_outside_brazil" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_own_profile"("p_full_name" "text", "p_age" integer, "p_city" "text", "p_education" "text", "p_zip_code" "text", "p_state" "text", "p_street" "text", "p_street_number" "text", "p_complement" "text", "p_passport_phase" "text", "p_relationship" "text", "p_isdependent" boolean, "p_parent_user_id" "uuid", "p_current_dependent_id" "uuid", "p_target_user_id" "uuid", "p_education_year" "text", "p_birth_date" "date", "p_neighborhood" "text", "p_country" "text", "p_outside_brazil" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_student_application_answers"("p_application_id" "uuid", "p_answers" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_student_application_answers"("p_application_id" "uuid", "p_answers" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_student_application_answers"("p_application_id" "uuid", "p_answers" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "partner";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";















GRANT ALL ON TABLE "public"."admin_alerts" TO "anon";
GRANT ALL ON TABLE "public"."admin_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_alerts" TO "service_role";



GRANT ALL ON TABLE "public"."agent_errors" TO "anon";
GRANT ALL ON TABLE "public"."agent_errors" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_errors" TO "service_role";
GRANT ALL ON TABLE "public"."agent_errors" TO "partner";



GRANT ALL ON TABLE "public"."agent_executions" TO "anon";
GRANT ALL ON TABLE "public"."agent_executions" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_executions" TO "service_role";



GRANT ALL ON TABLE "public"."agent_feedback" TO "anon";
GRANT ALL ON TABLE "public"."agent_feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_feedback" TO "service_role";
GRANT ALL ON TABLE "public"."agent_feedback" TO "partner";



GRANT ALL ON TABLE "public"."agent_prompt_versions" TO "anon";
GRANT ALL ON TABLE "public"."agent_prompt_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_prompt_versions" TO "service_role";



GRANT ALL ON TABLE "public"."agent_prompts" TO "anon";
GRANT ALL ON TABLE "public"."agent_prompts" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_prompts" TO "service_role";



GRANT ALL ON TABLE "public"."agent_turns" TO "anon";
GRANT ALL ON TABLE "public"."agent_turns" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_turns" TO "service_role";



GRANT ALL ON TABLE "public"."ai_insights" TO "anon";
GRANT ALL ON TABLE "public"."ai_insights" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_insights" TO "service_role";
GRANT ALL ON TABLE "public"."ai_insights" TO "partner";



GRANT ALL ON TABLE "public"."campaigns" TO "anon";
GRANT ALL ON TABLE "public"."campaigns" TO "authenticated";
GRANT ALL ON TABLE "public"."campaigns" TO "service_role";



GRANT ALL ON TABLE "public"."channel_links" TO "anon";
GRANT ALL ON TABLE "public"."channel_links" TO "authenticated";
GRANT ALL ON TABLE "public"."channel_links" TO "service_role";



GRANT ALL ON TABLE "public"."channel_mediums" TO "anon";
GRANT ALL ON TABLE "public"."channel_mediums" TO "authenticated";
GRANT ALL ON TABLE "public"."channel_mediums" TO "service_role";



GRANT ALL ON TABLE "public"."channels" TO "anon";
GRANT ALL ON TABLE "public"."channels" TO "authenticated";
GRANT ALL ON TABLE "public"."channels" TO "service_role";



GRANT ALL ON TABLE "public"."chat_messages" TO "anon";
GRANT ALL ON TABLE "public"."chat_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_messages" TO "service_role";
GRANT ALL ON TABLE "public"."chat_messages" TO "partner";



GRANT ALL ON TABLE "public"."cities" TO "anon";
GRANT ALL ON TABLE "public"."cities" TO "authenticated";
GRANT ALL ON TABLE "public"."cities" TO "service_role";
GRANT ALL ON TABLE "public"."cities" TO "partner";



GRANT ALL ON SEQUENCE "public"."cities_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cities_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cities_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."cities_id_seq" TO "partner";



GRANT ALL ON TABLE "public"."cloudinha_starters" TO "anon";
GRANT ALL ON TABLE "public"."cloudinha_starters" TO "authenticated";
GRANT ALL ON TABLE "public"."cloudinha_starters" TO "service_role";



GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "anon";
GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "service_role";
GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "partner";



GRANT ALL ON TABLE "public"."conversions" TO "anon";
GRANT ALL ON TABLE "public"."conversions" TO "authenticated";
GRANT ALL ON TABLE "public"."conversions" TO "service_role";



GRANT ALL ON TABLE "public"."course_groups" TO "anon";
GRANT ALL ON TABLE "public"."course_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."course_groups" TO "service_role";



GRANT ALL ON TABLE "public"."engagement_events" TO "anon";
GRANT ALL ON TABLE "public"."engagement_events" TO "authenticated";
GRANT ALL ON TABLE "public"."engagement_events" TO "service_role";



GRANT ALL ON TABLE "public"."etl_run_logs" TO "anon";
GRANT ALL ON TABLE "public"."etl_run_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."etl_run_logs" TO "service_role";



GRANT ALL ON TABLE "public"."external_redirect_clicks" TO "anon";
GRANT ALL ON TABLE "public"."external_redirect_clicks" TO "authenticated";
GRANT ALL ON TABLE "public"."external_redirect_clicks" TO "service_role";



GRANT ALL ON TABLE "public"."home_sections" TO "anon";
GRANT ALL ON TABLE "public"."home_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."home_sections" TO "service_role";



GRANT ALL ON TABLE "public"."influencers" TO "anon";
GRANT ALL ON TABLE "public"."influencers" TO "authenticated";
GRANT ALL ON TABLE "public"."influencers" TO "service_role";
GRANT ALL ON TABLE "public"."influencers" TO "partner";



GRANT ALL ON TABLE "public"."knowledge_categories" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_categories" TO "service_role";



GRANT ALL ON TABLE "public"."knowledge_document_opportunities" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_document_opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_document_opportunities" TO "service_role";



GRANT ALL ON TABLE "public"."knowledge_document_versions" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_document_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_document_versions" TO "service_role";



GRANT ALL ON TABLE "public"."knowledge_documents" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_documents" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_documents" TO "service_role";



GRANT ALL ON TABLE "public"."knowledge_keywords" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_keywords" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_keywords" TO "service_role";



GRANT ALL ON TABLE "public"."learning_examples" TO "anon";
GRANT ALL ON TABLE "public"."learning_examples" TO "authenticated";
GRANT ALL ON TABLE "public"."learning_examples" TO "service_role";
GRANT ALL ON TABLE "public"."learning_examples" TO "partner";



GRANT ALL ON TABLE "public"."match_config" TO "anon";
GRANT ALL ON TABLE "public"."match_config" TO "authenticated";
GRANT ALL ON TABLE "public"."match_config" TO "service_role";



GRANT ALL ON TABLE "public"."moderation_logs" TO "anon";
GRANT ALL ON TABLE "public"."moderation_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."moderation_logs" TO "service_role";
GRANT ALL ON TABLE "public"."moderation_logs" TO "partner";



GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "anon";
GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "authenticated";
GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "service_role";
GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "partner";



GRANT ALL ON TABLE "public"."opportunity_phases" TO "anon";
GRANT ALL ON TABLE "public"."opportunity_phases" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunity_phases" TO "service_role";



GRANT ALL ON TABLE "public"."partner_forms" TO "anon";
GRANT ALL ON TABLE "public"."partner_forms" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_forms" TO "service_role";
GRANT ALL ON TABLE "public"."partner_forms" TO "partner";



GRANT ALL ON TABLE "public"."partner_solicitation_attempts" TO "anon";
GRANT ALL ON TABLE "public"."partner_solicitation_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_solicitation_attempts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."partner_solicitation_attempts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."partner_solicitation_attempts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."partner_solicitation_attempts_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."partner_solicitations" TO "anon";
GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."partner_solicitations" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_solicitations" TO "service_role";
GRANT ALL ON TABLE "public"."partner_solicitations" TO "partner";



GRANT ALL ON TABLE "public"."partner_steps" TO "anon";
GRANT ALL ON TABLE "public"."partner_steps" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_steps" TO "service_role";



GRANT ALL ON TABLE "public"."partners_click" TO "anon";
GRANT ALL ON TABLE "public"."partners_click" TO "authenticated";
GRANT ALL ON TABLE "public"."partners_click" TO "service_role";
GRANT ALL ON TABLE "public"."partners_click" TO "partner";



GRANT ALL ON TABLE "public"."partners_users" TO "anon";
GRANT ALL ON TABLE "public"."partners_users" TO "authenticated";
GRANT ALL ON TABLE "public"."partners_users" TO "service_role";
GRANT ALL ON TABLE "public"."partners_users" TO "partner";



GRANT ALL ON TABLE "public"."platforms" TO "anon";
GRANT ALL ON TABLE "public"."platforms" TO "authenticated";
GRANT ALL ON TABLE "public"."platforms" TO "service_role";



GRANT ALL ON TABLE "public"."rawemec" TO "anon";
GRANT ALL ON TABLE "public"."rawemec" TO "authenticated";
GRANT ALL ON TABLE "public"."rawemec" TO "service_role";
GRANT ALL ON TABLE "public"."rawemec" TO "partner";



GRANT ALL ON TABLE "public"."rawprouni" TO "anon";
GRANT ALL ON TABLE "public"."rawprouni" TO "authenticated";
GRANT ALL ON TABLE "public"."rawprouni" TO "service_role";



GRANT ALL ON TABLE "public"."rawsisu" TO "anon";
GRANT ALL ON TABLE "public"."rawsisu" TO "authenticated";
GRANT ALL ON TABLE "public"."rawsisu" TO "service_role";



GRANT ALL ON TABLE "public"."rawsisuvacancies" TO "anon";
GRANT ALL ON TABLE "public"."rawsisuvacancies" TO "authenticated";
GRANT ALL ON TABLE "public"."rawsisuvacancies" TO "service_role";



GRANT ALL ON TABLE "public"."student_applications" TO "anon";
GRANT ALL ON TABLE "public"."student_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."student_applications" TO "service_role";
GRANT ALL ON TABLE "public"."student_applications" TO "partner";



GRANT ALL ON TABLE "public"."reversed_student_applications" TO "anon";
GRANT ALL ON TABLE "public"."reversed_student_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."reversed_student_applications" TO "service_role";



GRANT ALL ON TABLE "public"."sean_ellis_score" TO "anon";
GRANT ALL ON TABLE "public"."sean_ellis_score" TO "authenticated";
GRANT ALL ON TABLE "public"."sean_ellis_score" TO "service_role";
GRANT ALL ON TABLE "public"."sean_ellis_score" TO "partner";



GRANT ALL ON TABLE "public"."states" TO "anon";
GRANT ALL ON TABLE "public"."states" TO "authenticated";
GRANT ALL ON TABLE "public"."states" TO "service_role";
GRANT ALL ON TABLE "public"."states" TO "partner";



GRANT ALL ON TABLE "public"."system_intents" TO "anon";
GRANT ALL ON TABLE "public"."system_intents" TO "authenticated";
GRANT ALL ON TABLE "public"."system_intents" TO "service_role";



GRANT ALL ON TABLE "public"."user_attribution" TO "anon";
GRANT ALL ON TABLE "public"."user_attribution" TO "authenticated";
GRANT ALL ON TABLE "public"."user_attribution" TO "service_role";



GRANT ALL ON TABLE "public"."user_enem_scores" TO "anon";
GRANT ALL ON TABLE "public"."user_enem_scores" TO "authenticated";
GRANT ALL ON TABLE "public"."user_enem_scores" TO "service_role";
GRANT ALL ON TABLE "public"."user_enem_scores" TO "partner";



GRANT ALL ON TABLE "public"."user_favorites" TO "anon";
GRANT ALL ON TABLE "public"."user_favorites" TO "authenticated";
GRANT ALL ON TABLE "public"."user_favorites" TO "service_role";
GRANT ALL ON TABLE "public"."user_favorites" TO "partner";



GRANT ALL ON TABLE "public"."user_income" TO "anon";
GRANT ALL ON TABLE "public"."user_income" TO "authenticated";
GRANT ALL ON TABLE "public"."user_income" TO "service_role";



GRANT ALL ON TABLE "public"."user_opportunity_matches" TO "anon";
GRANT ALL ON TABLE "public"."user_opportunity_matches" TO "authenticated";
GRANT ALL ON TABLE "public"."user_opportunity_matches" TO "service_role";



GRANT ALL ON TABLE "public"."user_permissions" TO "anon";
GRANT ALL ON TABLE "public"."user_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_permissions" TO "service_role";
GRANT ALL ON TABLE "public"."user_permissions" TO "partner";



GRANT ALL ON TABLE "public"."user_preferences" TO "anon";
GRANT ALL ON TABLE "public"."user_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."user_preferences" TO "service_role";
GRANT ALL ON TABLE "public"."user_preferences" TO "partner";



GRANT ALL ON TABLE "public"."user_profiles" TO "anon";
GRANT ALL ON TABLE "public"."user_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_profiles" TO "service_role";
GRANT ALL ON TABLE "public"."user_profiles" TO "partner";



GRANT ALL ON TABLE "public"."user_rate_limits" TO "anon";
GRANT ALL ON TABLE "public"."user_rate_limits" TO "authenticated";
GRANT ALL ON TABLE "public"."user_rate_limits" TO "service_role";
GRANT ALL ON TABLE "public"."user_rate_limits" TO "partner";



GRANT ALL ON TABLE "public"."users_metadata" TO "anon";
GRANT ALL ON TABLE "public"."users_metadata" TO "authenticated";
GRANT ALL ON TABLE "public"."users_metadata" TO "service_role";



GRANT ALL ON TABLE "public"."v_unified_institutions" TO "anon";
GRANT ALL ON TABLE "public"."v_unified_institutions" TO "authenticated";
GRANT ALL ON TABLE "public"."v_unified_institutions" TO "service_role";



GRANT ALL ON TABLE "public"."vw_admin_user_funnel" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_user_funnel" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_user_funnel" TO "service_role";



GRANT ALL ON TABLE "public"."vw_favorite_courses_ranking" TO "anon";
GRANT ALL ON TABLE "public"."vw_favorite_courses_ranking" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_favorite_courses_ranking" TO "service_role";
GRANT ALL ON TABLE "public"."vw_favorite_courses_ranking" TO "partner";



GRANT ALL ON TABLE "public"."vw_partner_application_details" TO "anon";
GRANT ALL ON TABLE "public"."vw_partner_application_details" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_partner_application_details" TO "service_role";



GRANT ALL ON TABLE "public"."vw_partner_application_completion_buckets" TO "anon";
GRANT ALL ON TABLE "public"."vw_partner_application_completion_buckets" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_partner_application_completion_buckets" TO "service_role";



GRANT ALL ON TABLE "public"."vw_partner_funnel" TO "anon";
GRANT ALL ON TABLE "public"."vw_partner_funnel" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_partner_funnel" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
































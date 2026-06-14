


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



CREATE EXTENSION IF NOT EXISTS "cube" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "earthdistance" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






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


CREATE OR REPLACE FUNCTION "public"."calculate_passport_eligibility"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
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

    -- 2. Initialize results for ALL OPEN partners (changed from ALL partners)
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
        AND p.applications_open = true -- Added filter here as well to avoid processing closed partners
    LOOP
        -- Wrap EACH criterion in its own exception block so one failure doesn't break others
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
                -- Check if there's a submitted application for this partner
                -- Use p_user_id because applications are owned by the authenticated parent
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
                -- Increment total criteria
                v_partner_results := jsonb_set(v_partner_results, ARRAY[v_partner_id::text, 'total_criteria'], 
                    to_jsonb((v_partner_results->v_partner_id::text->>'total_criteria')::int + 1));

                -- Evaluate criterion rule
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

                -- Add detail
                v_partner_results := jsonb_set(v_partner_results, ARRAY[v_partner_id::text, 'details'], 
                    COALESCE(v_partner_results->v_partner_id::text->'details', '[]'::jsonb) || jsonb_build_object('field', v_form_record.field_name, 'met', v_met));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Log but don't break: this partner's criterion is skipped
            RAISE NOTICE 'Error processing criterion % for partner %: %', v_form_record.field_name, v_partner_id, SQLERRM;
        END;
    END LOOP;

    -- 4. Convert results object to array - Only open partners will be in this loop
    SELECT jsonb_agg(value) INTO v_results FROM jsonb_each(v_partner_results);
    IF v_results IS NULL THEN v_results := '[]'::jsonb; END IF;

    -- 5. Update user_profiles - Store results in the calling user's profile
    UPDATE public.user_profiles SET eligibility_results = v_results WHERE id = p_user_id;

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


CREATE OR REPLACE FUNCTION "public"."f_unaccent"("text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    AS $_$
SELECT public.unaccent('public.unaccent', $1)
$_$;


ALTER FUNCTION "public"."f_unaccent"("text") OWNER TO "postgres";


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
        p.name AS partner_name,
        COUNT(*) AS count
    FROM public.student_applications sa
    LEFT JOIN public.partners p ON p.id = sa.partner_id
    WHERE (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
      AND (p_days_ago IS NULL OR sa.created_at >= (now() - (p_days_ago || ' days')::interval))
    GROUP BY to_char(sa.created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD'), sa.partner_id, p.name
    ORDER BY date ASC;
END;
$$;


ALTER FUNCTION "public"."get_admin_applications_over_time"("p_partner_id" "uuid", "p_days_ago" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_funnel_users"() RETURNS TABLE("whatsapp" "text", "full_name" "text", "funnel_phase" "text", "step_order" integer, "furthest_passport_phase" "text", "active_partner_name" "text", "progress_percent" integer, "progress_filled" integer, "progress_total" integer, "is_dependent" boolean, "parent_full_name" "text", "external_redirect_clicks" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH latest_app AS (
        SELECT DISTINCT ON (sa.user_id) 
            sa.user_id,
            p.name AS partner_name,
            sa.status,
            sa.partner_id,
            (SELECT count(*) FROM jsonb_object_keys(sa.answers)) AS filled_count
        FROM public.student_applications sa
        JOIN public.partners p ON p.id = sa.partner_id
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


CREATE OR REPLACE FUNCTION "public"."get_eligible_count_for_partner"("p_partner_id" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_count BIGINT;
BEGIN
    SELECT COUNT(DISTINCT up.id) INTO v_count
    FROM public.user_profiles up,
         jsonb_array_elements(up.eligibility_results) AS elem
    WHERE (elem->>'partner_id')::uuid = p_partner_id
      AND (elem->>'met_criteria')::int = (elem->>'total_criteria')::int
      AND (elem->>'total_criteria')::int > 0;
      
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
            ), '[]'::jsonb)
        ) AS row_data
        FROM public.knowledge_documents kd
        LEFT JOIN public.knowledge_categories kc ON kd.category_id = kc.id
        LEFT JOIN public.partners p ON kd.partner_id = p.id
        WHERE (p_category_id IS NULL OR kd.category_id = p_category_id)
          AND (p_partner_id IS NULL OR kd.partner_id = p_partner_id)
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


CREATE OR REPLACE FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "user_id" "uuid", "partner_id" "uuid", "partner_name" "text", "full_name" "text", "phone" "text", "status" "text", "answers" "jsonb", "created_at" timestamp with time zone, "eligibility_results" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        sa.id,
        sa.user_id,
        sa.partner_id,
        p.name AS partner_name,
        up.full_name,
        u.phone,
        sa.status,
        sa.answers,
        sa.created_at,
        up.eligibility_results
    FROM
        public.student_applications sa
    LEFT JOIN
        public.user_profiles up ON sa.user_id = up.id
    LEFT JOIN
        auth.users u ON sa.user_id = u.id
    LEFT JOIN
        public.partners p ON sa.partner_id = p.id
    WHERE
        (p_partner_id IS NULL OR sa.partner_id = p_partner_id)
    ORDER BY
        sa.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_student_applications_with_details"("p_partner_id" "uuid") OWNER TO "postgres";


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
  v_order_clause TEXT;
BEGIN
  v_offset := p_page * p_page_size;

  -- Map sort_by to actual columns
  v_order_clause := CASE p_sort_by
    WHEN 'full_name' THEN 'p.full_name'
    WHEN 'city' THEN 'p.city'
    WHEN 'education' THEN 'p.education'
    WHEN 'is_nubo_student' THEN 'p.is_nubo_student'
    WHEN 'created_at' THEN 'p.created_at'
    ELSE 'p.created_at'
  END;

  -- 1. Calculate Total Count
  SELECT count(DISTINCT p.id) INTO v_total_count 
  FROM public.user_profiles p 
  LEFT JOIN public.user_preferences pref ON p.id = pref.user_id
  WHERE (p_filter_name IS NULL OR p.full_name ILIKE '%' || p_filter_name || '%')
    AND (p_filter_city IS NULL OR p.city ILIKE '%' || p_filter_city || '%')
    AND (p_filter_education IS NULL OR p.education ILIKE '%' || p_filter_education || '%')
    AND (p_filter_is_nubo_student IS NULL OR p.is_nubo_student = p_filter_is_nubo_student)
    AND (p_filter_income_min IS NULL OR pref.family_income_per_capita >= p_filter_income_min)
    AND (p_filter_income_max IS NULL OR pref.family_income_per_capita <= p_filter_income_max)
    AND (p_filter_quota_types IS NULL OR pref.quota_types && p_filter_quota_types)
    AND (p_filter_state IS NULL OR p.state = p_filter_state)
    AND (p_filter_age_min IS NULL OR p.age >= p_filter_age_min)
    AND (p_filter_age_max IS NULL OR p.age <= p_filter_age_max);

  -- 2. Fetch Data with dynamic sort
  EXECUTE format('
    SELECT coalesce(json_agg(t.*), ''[]''::json)
    FROM (
        SELECT DISTINCT ON (p.id) p.*, u.phone as whatsapp
        FROM public.user_profiles p
        LEFT JOIN public.user_preferences pref ON p.id = pref.user_id
        LEFT JOIN auth.users u ON p.id = u.id
        WHERE
          ($1 IS NULL OR p.full_name ILIKE ''%%'' || $1 || ''%%'')
          AND ($2 IS NULL OR p.city ILIKE ''%%'' || $2 || ''%%'')
          AND ($3 IS NULL OR p.education ILIKE ''%%'' || $3 || ''%%'')
          AND ($4 IS NULL OR p.is_nubo_student = $4)
          AND ($5 IS NULL OR pref.family_income_per_capita >= $5)
          AND ($6 IS NULL OR pref.family_income_per_capita <= $6)
          AND ($7 IS NULL OR pref.quota_types && $7)
          AND ($10 IS NULL OR p.state = $10)
          AND ($11 IS NULL OR p.age >= $11)
          AND ($12 IS NULL OR p.age <= $12)
        ORDER BY p.id, %s %s
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
    v_offset,
    p_filter_state,
    p_filter_age_min,
    p_filter_age_max
  INTO v_data;

  RETURN json_build_object('data', v_data, 'count', v_total_count);
END;
$_$;


ALTER FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) RETURNS TABLE("t_schema" "text", "t_name" "text", "c_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.table_schema::text as t_schema, 
        c.table_name::text as t_name, 
        c.column_name::text as c_name
    FROM information_schema.columns c
    WHERE 
        (c.table_schema = 'public' AND c.table_name = ANY(table_names))
        OR 
        (c.table_schema = 'auth' AND c.table_name = 'users' AND c.column_name IN ('email', 'phone'))
    ORDER BY c.table_schema, c.table_name, c.ordinal_position;
END;
$$;


ALTER FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) OWNER TO "postgres";


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
    CONSTRAINT "important_dates_type_check" CHECK (("type" = ANY (ARRAY['sisu'::"text", 'prouni'::"text", 'general'::"text", 'partners'::"text"])))
);


ALTER TABLE "public"."important_dates" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manage_important_date"("p_id" "uuid" DEFAULT NULL::"uuid", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_start_date" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_end_date" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_type" "text" DEFAULT NULL::"text", "p_delete" boolean DEFAULT false) RETURNS "public"."important_dates"
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
        -- Delete
        DELETE FROM public.important_dates WHERE id = p_id RETURNING * INTO v_date;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
        RETURN v_date;

    ELSIF p_id IS NULL THEN
        -- Create
        INSERT INTO public.important_dates (title, description, start_date, end_date, type)
        VALUES (p_title, p_description, p_start_date, p_end_date, p_type)
        RETURNING * INTO v_date;

    ELSE
        -- Update
        UPDATE public.important_dates
        SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            start_date = COALESCE(p_start_date, start_date),
            end_date = COALESCE(p_end_date, end_date),
            type = COALESCE(p_type, type)
        WHERE id = p_id
        RETURNING * INTO v_date;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
    END IF;

    RETURN v_date;
END;
$$;


ALTER FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean) OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."refresh_course_catalog"() RETURNS "void"
    LANGUAGE "sql"
    AS $$
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_course_catalog;
$$;


ALTER FUNCTION "public"."refresh_course_catalog"() OWNER TO "postgres";


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
    IF EXISTS (SELECT 1 FROM public.user_favorites WHERE user_id = v_user_id AND partner_id = p_id) THEN
      DELETE FROM public.user_favorites WHERE user_id = v_user_id AND partner_id = p_id;
    ELSE
      INSERT INTO public.user_favorites (user_id, partner_id) VALUES (v_user_id, p_id);
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid type. Must be "course" or "partner".';
  END IF;
END;
$$;


ALTER FUNCTION "public"."toggle_favorite"("p_type" "text", "p_id" "uuid") OWNER TO "postgres";


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


CREATE TABLE IF NOT EXISTS "public"."ai_insights" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "insights" "jsonb" NOT NULL,
    "data_context" "jsonb" NOT NULL,
    "data_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_insights" OWNER TO "postgres";


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


CREATE TABLE IF NOT EXISTS "public"."chat_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "sender" "text",
    "content" "text",
    "workflow" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    CONSTRAINT "chat_messages_sender_check" CHECK (("sender" = ANY (ARRAY['user'::"text", 'cloudinha'::"text"])))
);


ALTER TABLE "public"."chat_messages" OWNER TO "postgres";


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



CREATE TABLE IF NOT EXISTS "public"."concurrency_tag_rules" (
    "type_name" "text" NOT NULL,
    "tags" "jsonb"
);


ALTER TABLE "public"."concurrency_tag_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."courses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "campus_id" "uuid",
    "course_code" "text",
    "course_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "vacancies" "jsonb" DEFAULT '[]'::"jsonb",
    "occupied" "jsonb" DEFAULT '[]'::"jsonb",
    "vagas_ociosas_2025" "jsonb" DEFAULT '[]'::"jsonb"
);


ALTER TABLE "public"."courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "content" "text",
    "metadata" "jsonb",
    "embedding" "public"."vector"(768)
);


ALTER TABLE "public"."documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_redirect_clicks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "redirect_url" "text" NOT NULL,
    "source" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."external_redirect_clicks" OWNER TO "postgres";


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



CREATE TABLE IF NOT EXISTS "public"."institutions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "external_code" "text",
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."institutions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."institutions_info_emec" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "co_ies" "text",
    "no_ies" "text",
    "sigla" "text",
    "categoria" "text",
    "natureza" "text",
    "cidade" "text",
    "uf" "text",
    "igc_continuo" double precision,
    "igc_faixa" "text",
    "ci_continuo" double precision,
    "ci_faixa" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."institutions_info_emec" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."institutionsinfoemec" (
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


ALTER TABLE "public"."institutionsinfoemec" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."institutionsinfosisu" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "uuid",
    "acronym" "text",
    "academic_organization" "text",
    "administrative_category" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."institutionsinfosisu" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "label" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."knowledge_categories" OWNER TO "postgres";


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
    "partner_id" "uuid",
    "storage_path" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "current_version" integer DEFAULT 1 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
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


CREATE TABLE IF NOT EXISTS "public"."opportunitiessisuvacancies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "opportunity_id" "uuid",
    "qt_semestre" "text",
    "nu_vagas_autorizadas" "text",
    "qt_vagas_ofertadas" "text",
    "qt_vagas_ofertadas_2025" "text",
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
    "qt_inscricao_2025" "text",
    "vagas_ociosas_2025" integer,
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
    "nu_media_minima_enem" numeric
);


ALTER TABLE "public"."opportunitiessisuvacancies" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."mv_course_catalog" AS
 WITH "opportunity_aggregates" AS (
         SELECT "o"."course_id",
            "min"("o"."cutoff_score") AS "min_cutoff",
            "max"("o"."cutoff_score") AS "max_cutoff",
            "bool_or"(("o"."opportunity_type" = 'sisu'::"text")) AS "has_sisu",
            "bool_or"(("o"."opportunity_type" = 'prouni'::"text")) AS "has_prouni",
            "bool_or"((("o"."shift" ~~* '%EAD%'::"text") OR ("o"."shift" ~~* '%distância%'::"text"))) AS "has_ead",
            "bool_or"((("o"."is_nubo_pick" = true) OR (COALESCE("osv"."vagas_ociosas_2025", 0) > 0))) AS "has_nubo_pick",
            "bool_or"((EXISTS ( SELECT 1
                   FROM "jsonb_array_elements"("o"."concurrency_tags") "tags_group"("value")
                  WHERE (EXISTS ( SELECT 1
                           FROM "jsonb_array_elements_text"("tags_group"."value") "tag"("value")
                          WHERE ("tag"."value" <> ALL (ARRAY['AMPLA_CONCORRENCIA'::"text", 'MILITAR'::"text", 'OUTROS'::"text", 'BOLSA_PARCIAL'::"text", 'BOLSA_INTEGRAL'::"text"]))))))) AS "has_affirmative_action_tags",
            "json_agg"("json_build_object"('id', "o"."id", 'shift', "o"."shift", 'scholarship_type', "o"."scholarship_type", 'scholarship_type', "o"."scholarship_type", 'concurrency_type', "o"."concurrency_type", 'concurrency_tags', "o"."concurrency_tags", 'scholarship_tags', "o"."scholarship_tags", 'opportunity_type', "o"."opportunity_type", 'cutoff_score', "o"."cutoff_score", 'is_nubo_pick', (("o"."is_nubo_pick" = true) OR (COALESCE("osv"."vagas_ociosas_2025", 0) > 0)))) AS "opportunities_json"
           FROM ("public"."opportunities" "o"
             LEFT JOIN "public"."opportunitiessisuvacancies" "osv" ON (("osv"."opportunity_id" = "o"."id")))
          WHERE (("o"."semester" = '1'::"text") AND ((("o"."opportunity_type" = 'sisu'::"text") AND ("o"."year" = 2026)) OR (("o"."opportunity_type" = 'prouni'::"text") AND ("o"."year" = 2025))) AND (("o"."opportunity_type" <> 'sisu'::"text") OR ("osv"."qt_vagas_ofertadas" IS NULL) OR (("replace"("replace"(TRIM(BOTH FROM "osv"."qt_vagas_ofertadas"), '.'::"text", ''::"text"), ','::"text", '.'::"text"))::numeric > (0)::numeric)))
          GROUP BY "o"."course_id"
        )
 SELECT "c"."id" AS "course_id",
    "c"."course_name",
    "i"."name" AS "institution_name",
    "cp"."city",
    "cp"."state",
    "cp"."latitude",
    "cp"."longitude",
    "c"."vacancies" AS "vacancies_json",
    COALESCE("em"."igc", '0'::"text") AS "igc_raw",
        CASE
            WHEN ("em"."igc" = ANY (ARRAY['1'::"text", '2'::"text", '3'::"text", '4'::"text", '5'::"text"])) THEN ("em"."igc")::numeric
            ELSE (0)::numeric
        END AS "igc_value",
    "oa"."min_cutoff",
    "oa"."max_cutoff",
    COALESCE("oa"."has_sisu", false) AS "has_sisu",
    COALESCE("oa"."has_prouni", false) AS "has_prouni",
    COALESCE("oa"."has_ead", false) AS "has_ead",
    COALESCE("oa"."has_nubo_pick", false) AS "has_nubo_pick",
    (COALESCE("oa"."has_affirmative_action_tags", false) OR (( SELECT COALESCE("sum"((("elem"."value" ->> 'quotas_offered'::"text"))::numeric), (0)::numeric) AS "coalesce"
           FROM "jsonb_array_elements"("c"."vacancies") "elem"("value")) > (1)::numeric)) AS "has_affirmative_action",
    COALESCE("oa"."opportunities_json", '[]'::json) AS "opportunities_json",
    "to_tsvector"('"portuguese"'::"regconfig", (((("public"."unaccent"("c"."course_name") || ' '::"text") || "public"."unaccent"("i"."name")) || ' '::"text") || "public"."unaccent"("cp"."city"))) AS "search_vector"
   FROM (((("public"."courses" "c"
     JOIN "public"."campus" "cp" ON (("c"."campus_id" = "cp"."id")))
     JOIN "public"."institutions" "i" ON (("cp"."institution_id" = "i"."id")))
     LEFT JOIN "public"."institutionsinfoemec" "em" ON (("i"."id" = "em"."institution_id")))
     JOIN "opportunity_aggregates" "oa" ON (("c"."id" = "oa"."course_id")))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."mv_course_catalog" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nubo_student_whitelist" (
    "phone_number" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."nubo_student_whitelist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."opportunities_sisu_vacancies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "course_id" "uuid",
    "year" integer,
    "edition" integer,
    "modality" "text",
    "vacancies" integer,
    "min_grade" double precision,
    "max_grade" double precision,
    "avg_grade" double precision,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."opportunities_sisu_vacancies" OWNER TO "postgres";


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
    "conditional_rule" "jsonb"
);


ALTER TABLE "public"."partner_forms" OWNER TO "postgres";


COMMENT ON COLUMN "public"."partner_forms"."maskking" IS 'Input mask and validation type: cpf, cnpj, phone, cep, brl, email, date, number';



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


CREATE TABLE IF NOT EXISTS "public"."passport_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "eligible" boolean,
    "eligibility_details" "jsonb",
    "submitted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."passport_applications" OWNER TO "postgres";


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


CREATE TABLE IF NOT EXISTS "public"."rawprouni2025" (
    "ANO" "text",
    "SEMESTRE" "text",
    "CODIGO_IES" "text",
    "IES" "text",
    "CODIGO_CAMPUS" "text",
    "CAMPUS" "text",
    "CODIGO_CURSO" "text",
    "CURSO" "text",
    "MUNICIPIO" "text",
    "UF" "text",
    "CO_TURNO" "text",
    "TIPO_BOLSA" "text",
    "MODALIDADE_DO_CURSO" "text",
    "TP_MODALIDADE" "text",
    "GRAU_FORMACAO" "text",
    "NOTA_DE_CORTE" "text"
);


ALTER TABLE "public"."rawprouni2025" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawprouniocuppied" (
    "NU_ANO" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "CO_CAMPUS" "text",
    "NO_CAMPUS" "text",
    "CO_CURSO" "text",
    "NO_CURSO" "text",
    "DS_TIPO_BOLSA" "text",
    "BOLSAS_AMPLA_OCUPADA" "text",
    "BOLSAS_COTA_OCUPADA" "text"
);


ALTER TABLE "public"."rawprouniocuppied" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawprouniocuppied2025" (
    "NU_ANO" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "CO_CAMPUS" "text",
    "NO_CAMPUS" "text",
    "CO_CURSO" "text",
    "NO_CURSO" "text",
    "DS_TIPO_BOLSA" "text",
    "BOLSAS_AMPLA_OCUPADA" "text",
    "BOLSAS_COTA_OCUPADA" "text"
);


ALTER TABLE "public"."rawprouniocuppied2025" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawprounivacancies" (
    "NU_ANO" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "CO_CAMPUS" "text",
    "NO_CAMPUS" "text",
    "SG_UF_CAMPUS" "text",
    "NO_MUNICIPIO_CAMPUS" "text",
    "CO_CURSO" "text",
    "NO_CURSO" "text",
    "DS_TURNO" "text",
    "DS_GRAU" "text",
    "DS_TIPO_BOLSA" "text",
    "BOLSAS_AMPLA_OFERTADA" "text",
    "BOLSAS_COTA_OFERTADA" "text"
);


ALTER TABLE "public"."rawprounivacancies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawprounivacancies2025" (
    "NU_ANO" "text",
    "CO_IES" "text",
    "NO_IES" "text",
    "CO_CAMPUS" "text",
    "NO_CAMPUS" "text",
    "SG_UF_CAMPUS" "text",
    "NO_MUNICIPIO_CAMPUS" "text",
    "CO_CURSO" "text",
    "NO_CURSO" "text",
    "DS_TURNO" "text",
    "DS_GRAU" "text",
    "DS_TIPO_BOLSA" "text",
    "BOLSAS_AMPLA_OFERTADA" "text",
    "BOLSAS_COTA_OFERTADA" "text"
);


ALTER TABLE "public"."rawprounivacancies2025" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawsisu2025" (
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
    "QT_INSCRICAO" "text"
);


ALTER TABLE "public"."rawsisu2025" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawsisuapprovals2026" (
    "ID candidato" bigint NOT NULL,
    "NO_IES" "text",
    "SG_IES" "text",
    "NO_CAMPUS" "text",
    "NO_CURSO" "text",
    "DS_TURNO" "text",
    "TIPO_CONCORRENCIA" "text",
    "NO_MODALIDADE_CONCORRENCIA" "text",
    "NU_NOTA_CANDIDATO" "text",
    "NU_CLASSIFICACAO" bigint
);


ALTER TABLE "public"."rawsisuapprovals2026" OWNER TO "postgres";


COMMENT ON TABLE "public"."rawsisuapprovals2026" IS 'aprovacoes no sisu 2026';



CREATE TABLE IF NOT EXISTS "public"."rawsisuvacancies2025" (
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


ALTER TABLE "public"."rawsisuvacancies2025" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rawsisuvacancies2026" (
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


ALTER TABLE "public"."rawsisuvacancies2026" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'started'::"text" NOT NULL,
    "answers" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "student_applications_status_check" CHECK (("status" = ANY (ARRAY['started'::"text", 'eligible'::"text", 'ineligible'::"text", 'submitted'::"text", 'DRAFT'::"text", 'SUBMITTED'::"text", 'ELIGIBLE'::"text", 'INELIGIBLE'::"text"])))
);


ALTER TABLE "public"."student_applications" OWNER TO "postgres";


COMMENT ON COLUMN "public"."student_applications"."status" IS 'Application status. Supports both lowercase (legacy) and uppercase (standard) variants.';



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
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_enem_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_favorites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "course_id" "uuid",
    "partner_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_favorites_target_check" CHECK (((("course_id" IS NOT NULL) AND ("partner_id" IS NULL)) OR (("course_id" IS NULL) AND ("partner_id" IS NOT NULL))))
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
    "eligibility_results" "jsonb",
    "furthest_passport_phase" "text" DEFAULT 'INTRO'::"text",
    "birth_date" "date",
    "neighborhood" "text",
    "country" "text",
    "outside_brazil" boolean DEFAULT false,
    CONSTRAINT "user_profiles_furthest_passport_phase_check" CHECK (("furthest_passport_phase" = ANY (ARRAY['INTRO'::"text", 'ONBOARDING'::"text", 'ASK_DEPENDENT'::"text", 'DEPENDENT_ONBOARDING'::"text", 'PROGRAM_MATCH'::"text", 'EVALUATE'::"text", 'CONCLUDED'::"text"]))),
    CONSTRAINT "user_profiles_passport_phase_check" CHECK (("passport_phase" = ANY (ARRAY['INTRO'::"text", 'ONBOARDING'::"text", 'ASK_DEPENDENT'::"text", 'DEPENDENT_ONBOARDING'::"text", 'PROGRAM_MATCH'::"text", 'EVALUATE'::"text", 'CONCLUDED'::"text"])))
);


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."user_profiles"."referral_source" IS 'Source of the referral (e.g. influencer code) obtained from URL parameter "ref"';



COMMENT ON COLUMN "public"."user_profiles"."active_application_target_id" IS 'ID of the profile (self or dependent) currently being evaluated for an application.';



COMMENT ON COLUMN "public"."user_profiles"."eligibility_results" IS 'Latest eligibility evaluation results from evaluatePassportEligibilityTool.';



CREATE TABLE IF NOT EXISTS "public"."user_rate_limits" (
    "user_id" "uuid" NOT NULL,
    "last_message_at" timestamp with time zone DEFAULT "now"(),
    "message_count_window" integer DEFAULT 0
);


ALTER TABLE "public"."user_rate_limits" OWNER TO "postgres";


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


CREATE OR REPLACE VIEW "public"."vw_admin_funnel_chart" AS
 SELECT '1. Total de Usuários'::"text" AS "step_name",
    1 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
UNION ALL
 SELECT '2. Passaporte Iniciado'::"text" AS "step_name",
    2 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."passport_started" = true)
UNION ALL
 SELECT '3. 1ª Candidatura Iniciada'::"text" AS "step_name",
    3 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_started" >= 1)
UNION ALL
 SELECT '4. 1ª Candidatura Concluída'::"text" AS "step_name",
    4 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_submitted" >= 1)
UNION ALL
 SELECT '5. 2ª Candidatura Iniciada'::"text" AS "step_name",
    5 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_started" >= 2)
UNION ALL
 SELECT '6. 2ª Candidatura Concluída'::"text" AS "step_name",
    6 AS "step_order",
    "count"(*) AS "user_count"
   FROM "public"."vw_admin_user_funnel"
  WHERE ("vw_admin_user_funnel"."total_applications_submitted" >= 2);


ALTER VIEW "public"."vw_admin_funnel_chart" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_furthest_passport_phases" AS
 SELECT COALESCE("furthest_passport_phase", 'UNSTARTED'::"text") AS "furthest_passport_phase",
    "count"(*) AS "total_users"
   FROM "public"."user_profiles"
  WHERE ("created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
  GROUP BY "furthest_passport_phase";


ALTER VIEW "public"."vw_admin_furthest_passport_phases" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_passport_phases" AS
 SELECT COALESCE("passport_phase", 'UNSTARTED'::"text") AS "passport_phase",
    "count"(*) AS "total_users"
   FROM "public"."user_profiles"
  WHERE ("created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
  GROUP BY "passport_phase";


ALTER VIEW "public"."vw_admin_passport_phases" OWNER TO "postgres";


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
         SELECT "partners_click"."partner_id",
            "count"(DISTINCT "partners_click"."user_id") AS "total_unique_clicks"
           FROM "public"."partners_click"
          WHERE ("partners_click"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
          GROUP BY "partners_click"."partner_id"
        ), "partner_apps" AS (
         SELECT "student_applications"."partner_id",
            "count"(DISTINCT "student_applications"."user_id") AS "total_applications_started",
            "count"(DISTINCT
                CASE
                    WHEN ("student_applications"."status" = 'SUBMITTED'::"text") THEN "student_applications"."user_id"
                    ELSE NULL::"uuid"
                END) AS "total_applications_submitted"
           FROM "public"."student_applications"
          WHERE ("student_applications"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
          GROUP BY "student_applications"."partner_id"
        ), "external_clicks" AS (
         SELECT "external_redirect_clicks"."partner_id",
            "count"(DISTINCT "external_redirect_clicks"."user_id") AS "total_external_redirect_clicks"
           FROM "public"."external_redirect_clicks"
          WHERE ("external_redirect_clicks"."created_at" >= '2026-03-09 00:00:00+00'::timestamp with time zone)
          GROUP BY "external_redirect_clicks"."partner_id"
        )
 SELECT "p"."id" AS "partner_id",
    "p"."name" AS "partner_name",
    COALESCE("pc"."total_unique_clicks", (0)::bigint) AS "total_unique_clicks",
    COALESCE("pa"."total_applications_started", (0)::bigint) AS "total_applications_started",
    COALESCE("pa"."total_applications_submitted", (0)::bigint) AS "total_applications_submitted",
    COALESCE("ec"."total_external_redirect_clicks", (0)::bigint) AS "total_external_redirect_clicks"
   FROM ((("public"."partners" "p"
     LEFT JOIN "partner_clicks" "pc" ON (("p"."id" = "pc"."partner_id")))
     LEFT JOIN "partner_apps" "pa" ON (("p"."id" = "pa"."partner_id")))
     LEFT JOIN "external_clicks" "ec" ON (("p"."id" = "ec"."partner_id")));


ALTER VIEW "public"."vw_partner_funnel" OWNER TO "postgres";


ALTER TABLE ONLY "public"."cities" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."cities_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."agent_errors"
    ADD CONSTRAINT "agent_errors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_executions"
    ADD CONSTRAINT "agent_executions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_feedback"
    ADD CONSTRAINT "agent_feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_insights"
    ADD CONSTRAINT "ai_insights_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campus"
    ADD CONSTRAINT "campus_external_code_key" UNIQUE ("external_code");



ALTER TABLE ONLY "public"."campus"
    ADD CONSTRAINT "campus_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_name_state_key" UNIQUE ("name", "state");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."concurrency_tag_rules"
    ADD CONSTRAINT "concurrency_tag_rules_pkey" PRIMARY KEY ("type_name");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_campus_id_course_code_key" UNIQUE ("campus_id", "course_code");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_redirect_clicks"
    ADD CONSTRAINT "external_redirect_clicks_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."institutions"
    ADD CONSTRAINT "institutions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."institutionsinfoemec"
    ADD CONSTRAINT "institutionsinfoemec_institution_id_key" UNIQUE ("institution_id");



ALTER TABLE ONLY "public"."institutionsinfoemec"
    ADD CONSTRAINT "institutionsinfoemec_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."institutionsinfosisu"
    ADD CONSTRAINT "institutionsinfosisu_institution_id_key" UNIQUE ("institution_id");



ALTER TABLE ONLY "public"."institutionsinfosisu"
    ADD CONSTRAINT "institutionsinfosisu_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_categories"
    ADD CONSTRAINT "knowledge_categories_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."knowledge_categories"
    ADD CONSTRAINT "knowledge_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_document_versions"
    ADD CONSTRAINT "knowledge_document_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_documents"
    ADD CONSTRAINT "knowledge_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_keywords"
    ADD CONSTRAINT "knowledge_keywords_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."learning_examples"
    ADD CONSTRAINT "learning_examples_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."moderation_logs"
    ADD CONSTRAINT "moderation_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nubo_student_whitelist"
    ADD CONSTRAINT "nubo_student_whitelist_pkey" PRIMARY KEY ("phone_number");



ALTER TABLE ONLY "public"."opportunities"
    ADD CONSTRAINT "opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."opportunities_sisu_vacancies"
    ADD CONSTRAINT "opportunities_sisu_vacancies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."opportunitiessisuvacancies"
    ADD CONSTRAINT "opportunitiessisuvacancies_opportunity_id_key" UNIQUE ("opportunity_id");



ALTER TABLE ONLY "public"."opportunitiessisuvacancies"
    ADD CONSTRAINT "opportunitiessisuvacancies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_partner_id_field_name_key" UNIQUE ("partner_id", "field_name");



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."passport_applications"
    ADD CONSTRAINT "passport_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rawsisuapprovals2026"
    ADD CONSTRAINT "rawsisuapprovals2026_pkey" PRIMARY KEY ("ID candidato");



ALTER TABLE ONLY "public"."sean_ellis_score"
    ADD CONSTRAINT "sean_ellis_score_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."states"
    ADD CONSTRAINT "states_pkey" PRIMARY KEY ("uf");



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_user_id_partner_id_key" UNIQUE ("user_id", "partner_id");



ALTER TABLE ONLY "public"."user_enem_scores"
    ADD CONSTRAINT "user_enem_scores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_enem_scores"
    ADD CONSTRAINT "user_enem_scores_user_id_year_key" UNIQUE ("user_id", "year");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_course_unique" UNIQUE ("user_id", "course_id");



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_partner_unique" UNIQUE ("user_id", "partner_id");



ALTER TABLE ONLY "public"."user_income"
    ADD CONSTRAINT "user_income_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_income"
    ADD CONSTRAINT "user_income_user_id_unique" UNIQUE ("user_id");



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



CREATE INDEX "idx_ai_insights_created_at" ON "public"."ai_insights" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_campus_city_trgm_simple" ON "public"."campus" USING "gin" ("city" "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_city_unaccent" ON "public"."campus" USING "gin" ("public"."f_unaccent"("city") "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_city_unaccent_gin" ON "public"."campus" USING "gin" ("public"."f_unaccent"("city") "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_institution_id" ON "public"."campus" USING "btree" ("institution_id");



CREATE INDEX "idx_campus_join_opt" ON "public"."campus" USING "btree" ("institution_id", "name", "city");



CREATE INDEX "idx_campus_lat_long" ON "public"."campus" USING "gist" ("point"("longitude", "latitude"));



CREATE INDEX "idx_campus_state_unaccent" ON "public"."campus" USING "gin" ("public"."f_unaccent"("state") "public"."gin_trgm_ops");



CREATE INDEX "idx_campus_state_unaccent_gin" ON "public"."campus" USING "gin" ("public"."f_unaccent"("state") "public"."gin_trgm_ops");



CREATE INDEX "idx_chat_messages_user_created_at" ON "public"."chat_messages" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_cities_name_state" ON "public"."cities" USING "btree" ("name", "state");



CREATE INDEX "idx_cities_state" ON "public"."cities" USING "btree" ("state");



CREATE INDEX "idx_cities_unaccent_name" ON "public"."cities" USING "btree" ("public"."f_unaccent"("lower"("name")));



CREATE INDEX "idx_courses_course_name_trgm" ON "public"."courses" USING "gin" ("course_name" "public"."gin_trgm_ops");



CREATE INDEX "idx_courses_course_name_unaccent" ON "public"."courses" USING "gin" ("public"."f_unaccent"("course_name") "public"."gin_trgm_ops");



CREATE INDEX "idx_courses_join_opt" ON "public"."courses" USING "btree" ("campus_id", "course_code");



CREATE INDEX "idx_courses_name_unaccent_gin" ON "public"."courses" USING "gin" ("public"."f_unaccent"("course_name") "public"."gin_trgm_ops");



CREATE INDEX "idx_institutions_name_trgm" ON "public"."institutions" USING "gin" ("name" "public"."gin_trgm_ops");



CREATE INDEX "idx_institutions_name_unaccent_gin" ON "public"."institutions" USING "gin" ("public"."f_unaccent"("name") "public"."gin_trgm_ops");



CREATE INDEX "idx_institutionsinfoemec_admin_cat_gin" ON "public"."institutionsinfoemec" USING "gin" ("public"."f_unaccent"("administrative_category") "public"."gin_trgm_ops");



CREATE INDEX "idx_knowledge_documents_active" ON "public"."knowledge_documents" USING "btree" ("is_active");



CREATE INDEX "idx_knowledge_documents_category" ON "public"."knowledge_documents" USING "btree" ("category_id");



CREATE INDEX "idx_knowledge_documents_partner" ON "public"."knowledge_documents" USING "btree" ("partner_id");



CREATE INDEX "idx_knowledge_keywords_keyword" ON "public"."knowledge_keywords" USING "gin" ("keyword" "public"."gin_trgm_ops");



CREATE UNIQUE INDEX "idx_knowledge_keywords_unique" ON "public"."knowledge_keywords" USING "btree" ("document_id", "keyword");



CREATE INDEX "idx_knowledge_versions_document" ON "public"."knowledge_document_versions" USING "btree" ("document_id");



CREATE INDEX "idx_mv_course_catalog_city_state" ON "public"."mv_course_catalog" USING "btree" ("city", "state");



CREATE INDEX "idx_mv_course_catalog_filters" ON "public"."mv_course_catalog" USING "btree" ("has_sisu", "has_prouni", "has_ead", "has_affirmative_action", "has_nubo_pick");



CREATE INDEX "idx_mv_course_catalog_geo" ON "public"."mv_course_catalog" USING "btree" ("latitude", "longitude");



CREATE UNIQUE INDEX "idx_mv_course_catalog_id" ON "public"."mv_course_catalog" USING "btree" ("course_id");



CREATE INDEX "idx_mv_course_catalog_igc" ON "public"."mv_course_catalog" USING "btree" ("igc_value" DESC);



CREATE INDEX "idx_mv_course_catalog_max_cutoff" ON "public"."mv_course_catalog" USING "btree" ("max_cutoff" DESC NULLS LAST);



CREATE INDEX "idx_mv_course_catalog_min_cutoff" ON "public"."mv_course_catalog" USING "btree" ("min_cutoff");



CREATE INDEX "idx_mv_course_catalog_search" ON "public"."mv_course_catalog" USING "gin" ("search_vector");



CREATE INDEX "idx_opportunities_concurrency_tags" ON "public"."opportunities" USING "gin" ("concurrency_tags");



CREATE INDEX "idx_opportunities_concurrency_tags_text" ON "public"."opportunities" USING "gin" ((("concurrency_tags")::"text") "public"."gin_trgm_ops");



CREATE INDEX "idx_opportunities_concurrency_type" ON "public"."opportunities" USING "btree" ("concurrency_type");



CREATE INDEX "idx_opportunities_course_id" ON "public"."opportunities" USING "btree" ("course_id");



CREATE INDEX "idx_opportunities_cutoff_score" ON "public"."opportunities" USING "btree" ("cutoff_score");



CREATE INDEX "idx_opportunities_join_opt" ON "public"."opportunities" USING "btree" ("course_id", "shift", "concurrency_type", "year", "semester");



CREATE INDEX "idx_opportunities_search_lookup" ON "public"."opportunities" USING "btree" ("year", "semester", "opportunity_type", "cutoff_score");



CREATE INDEX "idx_opportunities_semester_type_year" ON "public"."opportunities" USING "btree" ("semester", "opportunity_type", "year");



CREATE INDEX "idx_opportunities_shift" ON "public"."opportunities" USING "btree" ("shift");



CREATE INDEX "idx_opportunities_timeline_type" ON "public"."opportunities" USING "btree" ("semester", "opportunity_type", "year");



CREATE INDEX "idx_opportunities_type_unaccent" ON "public"."opportunities" USING "btree" ("public"."f_unaccent"("opportunity_type"));



CREATE INDEX "idx_partner_forms_partner_id" ON "public"."partner_forms" USING "btree" ("partner_id");



CREATE INDEX "idx_partners_users_partner_id" ON "public"."partners_users" USING "btree" ("partner_id");



CREATE INDEX "idx_partners_users_user_id" ON "public"."partners_users" USING "btree" ("user_id");



CREATE INDEX "idx_rawsisu2025_join_opt" ON "public"."rawsisu2025" USING "btree" ("CO_IES", "NO_CAMPUS", "NO_MUNICIPIO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA");



CREATE INDEX "idx_rawsisu25_co_ies" ON "public"."rawsisuvacancies2025" USING "btree" ("CO_IES");



CREATE INDEX "idx_rawsisu25_mun_campus" ON "public"."rawsisuvacancies2025" USING "btree" ("NO_MUNICIPIO_CAMPUS");



CREATE INDEX "idx_rawsisu25_no_campus" ON "public"."rawsisuvacancies2025" USING "btree" ("NO_CAMPUS");



CREATE INDEX "idx_rawsisu26_co_ies" ON "public"."rawsisuvacancies2026" USING "btree" ("CO_IES");



CREATE INDEX "idx_rawsisu26_mun_campus" ON "public"."rawsisuvacancies2026" USING "btree" ("NO_MUNICIPIO_CAMPUS");



CREATE INDEX "idx_rawsisu26_no_campus" ON "public"."rawsisuvacancies2026" USING "btree" ("NO_CAMPUS");



CREATE INDEX "idx_rawsisuvacancies2025_join_opt" ON "public"."rawsisuvacancies2025" USING "btree" ("CO_IES", "NO_CAMPUS", "NO_MUNICIPIO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA");



CREATE INDEX "idx_rawsisuvacancies2026_join_opt" ON "public"."rawsisuvacancies2026" USING "btree" ("CO_IES", "NO_CAMPUS", "NO_MUNICIPIO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA");



CREATE INDEX "idx_sisu_vacancies_opportunity_id" ON "public"."opportunitiessisuvacancies" USING "btree" ("opportunity_id");



CREATE INDEX "idx_states_name_unaccent" ON "public"."states" USING "gin" ("public"."f_unaccent"("name") "public"."gin_trgm_ops");



CREATE INDEX "idx_student_applications_partner_id" ON "public"."student_applications" USING "btree" ("partner_id");



CREATE INDEX "idx_student_applications_status" ON "public"."student_applications" USING "btree" ("status");



CREATE INDEX "idx_student_applications_user_id" ON "public"."student_applications" USING "btree" ("user_id");



CREATE INDEX "idx_user_enem_scores_user_id" ON "public"."user_enem_scores" USING "btree" ("user_id");



CREATE INDEX "idx_user_favorites_course_id" ON "public"."user_favorites" USING "btree" ("course_id");



CREATE INDEX "idx_user_favorites_partner_id" ON "public"."user_favorites" USING "btree" ("partner_id");



CREATE INDEX "idx_user_favorites_user_id" ON "public"."user_favorites" USING "btree" ("user_id");



CREATE INDEX "idx_user_permissions_permission" ON "public"."user_permissions" USING "btree" ("permission");



CREATE INDEX "idx_user_preferences_user_id" ON "public"."user_preferences" USING "btree" ("user_id");



CREATE INDEX "idx_user_profiles_id" ON "public"."user_profiles" USING "btree" ("id");



CREATE OR REPLACE TRIGGER "before_insert_user_profiles_check_nubo" BEFORE INSERT ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."check_nubo_student_eligibility"();



CREATE OR REPLACE TRIGGER "on_score_change" AFTER INSERT OR UPDATE ON "public"."user_enem_scores" FOR EACH ROW EXECUTE FUNCTION "public"."update_best_enem_score"();



CREATE OR REPLACE TRIGGER "on_student_application_eligibility" AFTER INSERT OR UPDATE ON "public"."student_applications" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_calculate_passport_eligibility"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "update_furthest_passport_phase_trg" BEFORE UPDATE OF "passport_phase", "furthest_passport_phase" ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."trg_update_furthest_passport_phase"();



CREATE OR REPLACE TRIGGER "update_partner_forms_updated_at" BEFORE UPDATE ON "public"."partner_forms" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_partners_click_updated_at" BEFORE UPDATE ON "public"."partners_click" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_partners_updated_at" BEFORE UPDATE ON "public"."partners" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_student_applications_updated_at" BEFORE UPDATE ON "public"."student_applications" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."agent_errors"
    ADD CONSTRAINT "agent_errors_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_errors"
    ADD CONSTRAINT "agent_errors_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_feedback"
    ADD CONSTRAINT "agent_feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."campus"
    ADD CONSTRAINT "campus_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_campus_id_fkey" FOREIGN KEY ("campus_id") REFERENCES "public"."campus"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_redirect_clicks"
    ADD CONSTRAINT "external_redirect_clicks_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id");



ALTER TABLE ONLY "public"."external_redirect_clicks"
    ADD CONSTRAINT "external_redirect_clicks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."institutionsinfoemec"
    ADD CONSTRAINT "institutionsinfoemec_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."institutionsinfosisu"
    ADD CONSTRAINT "institutionsinfosisu_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "public"."institutions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_document_versions"
    ADD CONSTRAINT "knowledge_document_versions_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."knowledge_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_documents"
    ADD CONSTRAINT "knowledge_documents_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."knowledge_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."knowledge_documents"
    ADD CONSTRAINT "knowledge_documents_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."knowledge_keywords"
    ADD CONSTRAINT "knowledge_keywords_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."knowledge_documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."opportunities"
    ADD CONSTRAINT "opportunities_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."opportunities_sisu_vacancies"
    ADD CONSTRAINT "opportunities_sisu_vacancies_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id");



ALTER TABLE ONLY "public"."opportunitiessisuvacancies"
    ADD CONSTRAINT "opportunitiessisuvacancies_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."opportunities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_forms"
    ADD CONSTRAINT "partner_forms_step_id_fkey" FOREIGN KEY ("step_id") REFERENCES "public"."partner_steps"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partner_steps"
    ADD CONSTRAINT "partner_steps_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partners_click"
    ADD CONSTRAINT "partners_click_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id");



ALTER TABLE ONLY "public"."partners_click"
    ADD CONSTRAINT "partners_click_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."partners_users"
    ADD CONSTRAINT "partners_users_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partners_users"
    ADD CONSTRAINT "partners_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."passport_applications"
    ADD CONSTRAINT "passport_applications_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id");



ALTER TABLE ONLY "public"."passport_applications"
    ADD CONSTRAINT "passport_applications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id");



ALTER TABLE ONLY "public"."sean_ellis_score"
    ADD CONSTRAINT "sean_ellis_score_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_applications"
    ADD CONSTRAINT "student_applications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_enem_scores"
    ADD CONSTRAINT "user_enem_scores_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorites"
    ADD CONSTRAINT "user_favorites_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_income"
    ADD CONSTRAINT "user_income_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



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



CREATE POLICY "Allow public insert to partner_solicitations" ON "public"."partner_solicitations" FOR INSERT WITH CHECK (true);



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



CREATE POLICY "Public can read institutionsinfoemec" ON "public"."institutionsinfoemec" FOR SELECT USING (true);



CREATE POLICY "Public can read institutionsinfosisu" ON "public"."institutionsinfosisu" FOR SELECT USING (true);



CREATE POLICY "Public can read opportunities" ON "public"."opportunities" FOR SELECT USING (true);



CREATE POLICY "Public can read partners" ON "public"."partners" FOR SELECT USING (true);



CREATE POLICY "Public read access to active influencers" ON "public"."influencers" FOR SELECT USING (("active" = true));



CREATE POLICY "Service role can insert errors" ON "public"."agent_errors" FOR INSERT TO "authenticated", "service_role" WITH CHECK (true);



CREATE POLICY "Service role can manage learning examples" ON "public"."learning_examples" USING (true) WITH CHECK (true);



CREATE POLICY "Service role can view errors" ON "public"."agent_errors" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Service role has full access to user_income" ON "public"."user_income" USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "Users can delete own favorites" ON "public"."user_favorites" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own scores" ON "public"."user_enem_scores" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own applications" ON "public"."student_applications" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own clicks" ON "public"."partners_click" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own favorites" ON "public"."user_favorites" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own feedback" ON "public"."agent_feedback" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own messages" ON "public"."chat_messages" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own profile" ON "public"."user_profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert own rate limits" ON "public"."user_rate_limits" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own feedback" ON "public"."agent_feedback" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own income" ON "public"."user_income" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own preferences" ON "public"."user_preferences" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own redirect clicks" ON "public"."external_redirect_clicks" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own scores" ON "public"."user_enem_scores" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert/update their own partner clicks" ON "public"."partners_click" TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



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



ALTER TABLE "public"."agent_errors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agent_feedback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_insights" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."campus" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_redirect_clicks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."important_dates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."influencers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."institutions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."institutionsinfoemec" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."institutionsinfosisu" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."knowledge_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_categories_read" ON "public"."knowledge_categories" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."knowledge_document_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_document_versions_read" ON "public"."knowledge_document_versions" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."knowledge_documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_documents_read" ON "public"."knowledge_documents" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."knowledge_keywords" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "knowledge_keywords_read" ON "public"."knowledge_keywords" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."learning_examples" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."moderation_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."opportunities" ENABLE ROW LEVEL SECURITY;


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



ALTER TABLE "public"."rawprouni2025" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rawprounivacancies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rawprounivacancies2025" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rawsisu2025" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rawsisuapprovals2026" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rawsisuvacancies2025" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rawsisuvacancies2026" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sean_ellis_score" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_applications_insert_own" ON "public"."student_applications" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "student_applications_select_own" ON "public"."student_applications" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "student_applications_select_partner" ON "public"."student_applications" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."partners_users" "pu"
  WHERE (("pu"."user_id" = "auth"."uid"()) AND ("pu"."partner_id" = "student_applications"."partner_id")))));



CREATE POLICY "student_applications_update_own" ON "public"."student_applications" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_enem_scores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_income" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_rate_limits" ENABLE ROW LEVEL SECURITY;




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



GRANT ALL ON FUNCTION "public"."f_unaccent"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."f_unaccent"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."f_unaccent"("text") TO "service_role";
GRANT ALL ON FUNCTION "public"."f_unaccent"("text") TO "partner";



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



GRANT ALL ON FUNCTION "public"."get_admin_funnel_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_funnel_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_funnel_users"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_backoffice_users"() TO "partner";



GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_chat_analytics_summary"("p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "partner";



GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_courses_with_opportunities"("page_number" integer, "page_size" integer, "search_query" "text", "category" "text", "sort_by" "text", "user_city" "text", "user_state" "text", "user_lat" double precision, "user_long" double precision) TO "partner";



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



GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_own_profile"() TO "partner";



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



GRANT ALL ON FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_details_v2"("p_student_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_student_stats"("filter_full_name" "text", "filter_city" "text", "filter_education" "text", "filter_is_nubo_student" boolean, "filter_income_min" numeric, "filter_income_max" numeric, "filter_quota_types" "text"[], "filter_state" "text", "filter_age_min" integer, "filter_age_max" integer) TO "partner";



GRANT ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."get_students_paginated"("p_page" integer, "p_page_size" integer, "p_filter_name" "text", "p_filter_city" "text", "p_filter_education" "text", "p_filter_is_nubo_student" boolean, "p_filter_income_min" numeric, "p_filter_income_max" numeric, "p_filter_quota_types" "text"[], "p_sort_by" "text", "p_sort_order" "text", "p_filter_state" "text", "p_filter_age_min" integer, "p_filter_age_max" integer) TO "partner";



GRANT ALL ON FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_table_columns_for_mapping"("table_names" "text"[]) TO "service_role";



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



GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."manage_important_date"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_type" "text", "p_delete" boolean) TO "partner";



GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manage_knowledge_document"("p_id" "uuid", "p_title" "text", "p_description" "text", "p_category_id" "uuid", "p_partner_id" "uuid", "p_storage_path" "text", "p_is_active" boolean, "p_keywords" "text"[], "p_change_summary" "text", "p_delete" boolean) TO "service_role";



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



GRANT ALL ON FUNCTION "public"."refresh_course_catalog"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_course_catalog"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_course_catalog"() TO "service_role";
GRANT ALL ON FUNCTION "public"."refresh_course_catalog"() TO "partner";



GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."safe_to_numeric"("val" "text") TO "partner";



GRANT ALL ON FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_knowledge_by_keyword"("p_keyword" "text", "p_partner_id" "uuid", "p_category_name" "text") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."trg_update_furthest_passport_phase"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_update_furthest_passport_phase"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_update_furthest_passport_phase"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_calculate_passport_eligibility"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_calculate_passport_eligibility"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_calculate_passport_eligibility"() TO "service_role";



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



GRANT ALL ON TABLE "public"."ai_insights" TO "anon";
GRANT ALL ON TABLE "public"."ai_insights" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_insights" TO "service_role";
GRANT ALL ON TABLE "public"."ai_insights" TO "partner";



GRANT ALL ON TABLE "public"."campus" TO "anon";
GRANT ALL ON TABLE "public"."campus" TO "authenticated";
GRANT ALL ON TABLE "public"."campus" TO "service_role";
GRANT ALL ON TABLE "public"."campus" TO "partner";



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



GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "anon";
GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "service_role";
GRANT ALL ON TABLE "public"."concurrency_tag_rules" TO "partner";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";
GRANT ALL ON TABLE "public"."courses" TO "partner";



GRANT ALL ON TABLE "public"."documents" TO "anon";
GRANT ALL ON TABLE "public"."documents" TO "authenticated";
GRANT ALL ON TABLE "public"."documents" TO "service_role";
GRANT ALL ON TABLE "public"."documents" TO "partner";



GRANT ALL ON TABLE "public"."external_redirect_clicks" TO "anon";
GRANT ALL ON TABLE "public"."external_redirect_clicks" TO "authenticated";
GRANT ALL ON TABLE "public"."external_redirect_clicks" TO "service_role";



GRANT ALL ON TABLE "public"."influencers" TO "anon";
GRANT ALL ON TABLE "public"."influencers" TO "authenticated";
GRANT ALL ON TABLE "public"."influencers" TO "service_role";
GRANT ALL ON TABLE "public"."influencers" TO "partner";



GRANT ALL ON TABLE "public"."institutions" TO "anon";
GRANT ALL ON TABLE "public"."institutions" TO "authenticated";
GRANT ALL ON TABLE "public"."institutions" TO "service_role";
GRANT ALL ON TABLE "public"."institutions" TO "partner";



GRANT ALL ON TABLE "public"."institutions_info_emec" TO "anon";
GRANT ALL ON TABLE "public"."institutions_info_emec" TO "authenticated";
GRANT ALL ON TABLE "public"."institutions_info_emec" TO "service_role";



GRANT ALL ON TABLE "public"."institutionsinfoemec" TO "anon";
GRANT ALL ON TABLE "public"."institutionsinfoemec" TO "authenticated";
GRANT ALL ON TABLE "public"."institutionsinfoemec" TO "service_role";
GRANT ALL ON TABLE "public"."institutionsinfoemec" TO "partner";



GRANT ALL ON TABLE "public"."institutionsinfosisu" TO "anon";
GRANT ALL ON TABLE "public"."institutionsinfosisu" TO "authenticated";
GRANT ALL ON TABLE "public"."institutionsinfosisu" TO "service_role";
GRANT ALL ON TABLE "public"."institutionsinfosisu" TO "partner";



GRANT ALL ON TABLE "public"."knowledge_categories" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_categories" TO "service_role";



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



GRANT ALL ON TABLE "public"."moderation_logs" TO "anon";
GRANT ALL ON TABLE "public"."moderation_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."moderation_logs" TO "service_role";
GRANT ALL ON TABLE "public"."moderation_logs" TO "partner";



GRANT ALL ON TABLE "public"."opportunities" TO "anon";
GRANT ALL ON TABLE "public"."opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunities" TO "service_role";
GRANT ALL ON TABLE "public"."opportunities" TO "partner";



GRANT ALL ON TABLE "public"."opportunitiessisuvacancies" TO "anon";
GRANT ALL ON TABLE "public"."opportunitiessisuvacancies" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunitiessisuvacancies" TO "service_role";
GRANT ALL ON TABLE "public"."opportunitiessisuvacancies" TO "partner";



GRANT ALL ON TABLE "public"."mv_course_catalog" TO "anon";
GRANT ALL ON TABLE "public"."mv_course_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."mv_course_catalog" TO "service_role";
GRANT ALL ON TABLE "public"."mv_course_catalog" TO "partner";



GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "anon";
GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "authenticated";
GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "service_role";
GRANT ALL ON TABLE "public"."nubo_student_whitelist" TO "partner";



GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "anon";
GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "authenticated";
GRANT ALL ON TABLE "public"."opportunities_sisu_vacancies" TO "service_role";



GRANT ALL ON TABLE "public"."partner_forms" TO "anon";
GRANT ALL ON TABLE "public"."partner_forms" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_forms" TO "service_role";
GRANT ALL ON TABLE "public"."partner_forms" TO "partner";



GRANT ALL ON TABLE "public"."partner_solicitations" TO "anon";
GRANT ALL ON TABLE "public"."partner_solicitations" TO "authenticated";
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



GRANT ALL ON TABLE "public"."passport_applications" TO "anon";
GRANT ALL ON TABLE "public"."passport_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."passport_applications" TO "service_role";



GRANT ALL ON TABLE "public"."rawemec" TO "anon";
GRANT ALL ON TABLE "public"."rawemec" TO "authenticated";
GRANT ALL ON TABLE "public"."rawemec" TO "service_role";
GRANT ALL ON TABLE "public"."rawemec" TO "partner";



GRANT ALL ON TABLE "public"."rawprouni2025" TO "anon";
GRANT ALL ON TABLE "public"."rawprouni2025" TO "authenticated";
GRANT ALL ON TABLE "public"."rawprouni2025" TO "service_role";
GRANT ALL ON TABLE "public"."rawprouni2025" TO "partner";



GRANT ALL ON TABLE "public"."rawprouniocuppied" TO "anon";
GRANT ALL ON TABLE "public"."rawprouniocuppied" TO "authenticated";
GRANT ALL ON TABLE "public"."rawprouniocuppied" TO "service_role";



GRANT ALL ON TABLE "public"."rawprouniocuppied2025" TO "anon";
GRANT ALL ON TABLE "public"."rawprouniocuppied2025" TO "authenticated";
GRANT ALL ON TABLE "public"."rawprouniocuppied2025" TO "service_role";



GRANT ALL ON TABLE "public"."rawprounivacancies" TO "anon";
GRANT ALL ON TABLE "public"."rawprounivacancies" TO "authenticated";
GRANT ALL ON TABLE "public"."rawprounivacancies" TO "service_role";
GRANT ALL ON TABLE "public"."rawprounivacancies" TO "partner";



GRANT ALL ON TABLE "public"."rawprounivacancies2025" TO "anon";
GRANT ALL ON TABLE "public"."rawprounivacancies2025" TO "authenticated";
GRANT ALL ON TABLE "public"."rawprounivacancies2025" TO "service_role";
GRANT ALL ON TABLE "public"."rawprounivacancies2025" TO "partner";



GRANT ALL ON TABLE "public"."rawsisu2025" TO "anon";
GRANT ALL ON TABLE "public"."rawsisu2025" TO "authenticated";
GRANT ALL ON TABLE "public"."rawsisu2025" TO "service_role";
GRANT ALL ON TABLE "public"."rawsisu2025" TO "partner";



GRANT ALL ON TABLE "public"."rawsisuapprovals2026" TO "anon";
GRANT ALL ON TABLE "public"."rawsisuapprovals2026" TO "authenticated";
GRANT ALL ON TABLE "public"."rawsisuapprovals2026" TO "service_role";



GRANT ALL ON TABLE "public"."rawsisuvacancies2025" TO "anon";
GRANT ALL ON TABLE "public"."rawsisuvacancies2025" TO "authenticated";
GRANT ALL ON TABLE "public"."rawsisuvacancies2025" TO "service_role";
GRANT ALL ON TABLE "public"."rawsisuvacancies2025" TO "partner";



GRANT ALL ON TABLE "public"."rawsisuvacancies2026" TO "anon";
GRANT ALL ON TABLE "public"."rawsisuvacancies2026" TO "authenticated";
GRANT ALL ON TABLE "public"."rawsisuvacancies2026" TO "service_role";
GRANT ALL ON TABLE "public"."rawsisuvacancies2026" TO "partner";



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



GRANT ALL ON TABLE "public"."vw_admin_user_funnel" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_user_funnel" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_user_funnel" TO "service_role";



GRANT ALL ON TABLE "public"."vw_admin_funnel_chart" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_funnel_chart" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_funnel_chart" TO "service_role";



GRANT ALL ON TABLE "public"."vw_admin_furthest_passport_phases" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_furthest_passport_phases" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_furthest_passport_phases" TO "service_role";



GRANT ALL ON TABLE "public"."vw_admin_passport_phases" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_passport_phases" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_passport_phases" TO "service_role";



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
































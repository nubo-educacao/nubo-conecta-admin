-- =============================================================================
-- Backfill de renda via mapping_source  (2026-08-03)
-- =============================================================================
-- ⚠️ RECUPERADA DE PRODUÇÃO EM 13/08/2026.
--    Esta migration foi aplicada direto em prod e nunca versionada. O conteúdo
--    abaixo foi extraído de supabase_migrations.schema_migrations, não
--    reescrito — reescrever de memória é como uma migration vira duas verdades.
--    Ela e a 20260803160000 eram a diferença inteira entre git e prod.
--
-- CONTEXTO
--   partner_forms.mapping_source suporta 3 prefixos: user_profiles.%,
--   user_preferences.% e user_income.%. A funcao backfill_eligibility_and_mappings
--   tratava apenas os dois primeiros: nenhum caminho no banco jamais escreveu em
--   public.user_income. O unico writer era o app (partner-forms/[id]/page.tsx),
--   que so passou a inserir linhas novas apos o fix da semana de 2026-07-27.
--   Resultado em prod: 49 usuarios com resposta de renda estruturada e
--   per_capita_income ausente (48 sem linha, 1 com linha e coluna NULL).
--
-- ESTE ARQUIVO FAZ DUAS COISAS
--   PARTE 1 - backfill pontual e idempotente dos 49 casos recuperaveis.
--   PARTE 2 - corrige backfill_eligibility_and_mappings para tratar user_income.%.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- PARTE 1 - Backfill pontual
-- -----------------------------------------------------------------------------
-- Inclui applications em DRAFT de proposito: renda e dado de PERFIL do usuario,
-- nao artefato da candidatura. Sao 11 dos 49 casos em prod.
WITH mapped AS (
  SELECT partner_id, field_name
  FROM public.partner_forms
  WHERE mapping_source = 'user_income.per_capita_income'
),
answers AS (
  SELECT
    sa.user_id,
    sa.created_at,
    (sa.answers ->> m.field_name)::jsonb AS payload
  FROM public.student_applications sa
  JOIN mapped m ON m.partner_id = sa.partner_id
  -- apenas o formato estruturado do income_calculator; faixas textuais fora
  WHERE sa.answers ->> m.field_name LIKE '{%'
),
latest AS (
  SELECT DISTINCT ON (user_id) user_id, payload
  FROM answers
  ORDER BY user_id, created_at DESC
),
src AS (
  SELECT
    l.user_id,
    NULLIF(l.payload ->> 'family_count', '')::integer     AS family_count,
    NULLIF(l.payload ->> 'social_benefits', '')::numeric  AS social_benefits,
    NULLIF(l.payload ->> 'alimony', '')::numeric          AS alimony,
    CASE WHEN jsonb_typeof(l.payload -> 'member_incomes') = 'array'
         THEN l.payload -> 'member_incomes' END           AS member_incomes,
    NULLIF(l.payload ->> 'per_capita_income', '')::numeric AS per_capita_income
  FROM latest l
  WHERE l.payload ->> 'per_capita_income' IS NOT NULL
)
INSERT INTO public.user_income
  (user_id, family_count, social_benefits, alimony, member_incomes, per_capita_income)
SELECT
  user_id, family_count, social_benefits, alimony, member_incomes, per_capita_income
FROM src
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

-- -----------------------------------------------------------------------------
-- PARTE 2 - backfill_eligibility_and_mappings passa a tratar user_income.%
-- -----------------------------------------------------------------------------
-- DROP explicito da assinatura exata antes do CREATE: um CREATE OR REPLACE com
-- assinatura diferente criaria uma SEGUNDA funcao e a antiga continuaria
-- atendendo as chamadas.
DROP FUNCTION IF EXISTS public.backfill_eligibility_and_mappings();

CREATE FUNCTION public.backfill_eligibility_and_mappings()
RETURNS TABLE(processed_count integer, error_count integer, success boolean)
LANGUAGE plpgsql
SECURITY DEFINER
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
$function$;

COMMENT ON FUNCTION public.backfill_eligibility_and_mappings() IS
  'Reprocessa applications SUBMITTED/redirected aplicando partner_forms.mapping_source '
  'para user_profiles.%, user_preferences.% e user_income.% (fill-if-null). '
  'Respostas de renda em faixa textual sao ignoradas por nao serem per capita.';

COMMIT;

-- =============================================================================
-- PARTE 3 - Pendencias que este arquivo NAO resolve (registro deliberado)
-- =============================================================================
--  a) ~322 usuarios com resposta de renda em faixa textual ("Ate 1 salario
--     minimo"). Faixa de renda FAMILIAR nao e renda PER CAPITA: gravar isso em
--     per_capita_income corromperia a elegibilidade. Requer decisao de produto
--     sobre como converter, ou nova coleta.
--  b) Divergencias app-vs-perfil por perfil estagnado: tratadas na migration
--     seguinte, 20260803160000.
--
-- ⚠️ NOTA DE SEGURANCA (auditoria de 13/08/2026, TP-6 achado #9)
--    Esta funcao e SECURITY DEFINER, nao fixa search_path e tem EXECUTE para
--    PUBLIC — ou seja, e um caminho de ESCRITA acionavel por qualquer um com a
--    anon key. Reproduzido aqui como esta em producao para nao alterar
--    comportamento numa migration de reconciliacao. O hardening e trabalho
--    proprio, com seu proprio teste.
-- =============================================================================

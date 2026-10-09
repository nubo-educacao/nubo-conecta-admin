-- =============================================================================
-- Migration: search_levenshtein_typos
-- A busca (20261009150000) tolera erros via similaridade de palavra (pg_trgm, 0.5),
-- que falha quando falta uma letra numa palavra curta: "mdcina" x "medicina" = 0.43.
--
-- Terceiro nível de tolerância, só para palavras sem casamento exato nem por
-- similaridade 0.5: candidatos pelo índice GIN com similaridade estrita 0.3 (<<%,
-- limiar próprio, não afeta o <%) e confirmação por distância de edição (Levenshtein,
-- extensão fuzzystrmatch) contra as palavras do documento: até 1 letra em palavras
-- de até 4 caracteres, 2 até 8, 3 acima.
-- Resto da função idêntico a 20261009150000.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA public;

CREATE OR REPLACE FUNCTION public.search_opportunities_v2(
  p_q    text,
  p_lat  double precision DEFAULT NULL,
  p_long double precision DEFAULT NULL
)
RETURNS TABLE (
  unified_id text, title text, provider_name text, type text,
  opportunity_type text, category text, is_partner boolean, location text,
  badges jsonb, created_at timestamptz, external_redirect_url text,
  external_redirect_enabled boolean, status text, starts_at timestamptz,
  ends_at timestamptz, match_score numeric, institution_cover_url text,
  nu_vagas_autorizadas text, institution_id uuid, institution_igc text,
  institution_organization text, institution_category text, institution_site text,
  eligibility_criteria jsonb, benefits jsonb, brand_color text, weights jsonb,
  institution_acronym text, latitude double precision, longitude double precision,
  min_cutoff_score_current numeric, min_cutoff_score_prev numeric,
  max_cutoff_score_current numeric, max_cutoff_score_prev numeric,
  qt_vagas_ofertadas_current text, qt_vagas_ofertadas_prev text,
  qt_inscricao_current text, qt_inscricao_prev text,
  nu_media_minima_enem_current numeric, nu_media_minima_enem_prev numeric,
  vagas_ociosas_current boolean, vagas_ociosas_prev boolean,
  search_text text, distance_km double precision, search_rank real
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_q       text;
  v_full    text;
  v_groups  jsonb := '[]'::jsonb;   -- array de grupos; cada grupo = array de alternativas
  v_group   jsonb;
  v_alt     text;
  v_syn     record;
  v_tok     text;
  v_conds   text[] := '{}';
  v_fuzzy_conds text[] := '{}';
  v_group_exact boolean;
  v_ranks   text[] := '{}';
  v_alt_conds text[];
  v_alt_ranks text[];
  v_cond    text;
  v_kept    text[] := '{}';
  v_where   text;
  v_select  text;
  v_exists  boolean;
  v_max_dist integer;
BEGIN
  -- Limiar de similaridade 0.5 (padrão do pg_trgm é 0.6, que perde "medcina", "nutrisao").
  -- Não dá para usar "SET pg_trgm..." na assinatura: em produção o papel das migrations não
  -- pode fixar parâmetro de extensão ainda não carregada (42501). Em tempo de execução,
  -- depois de carregar o pg_trgm, o ajuste é permitido; vale só para esta transação.
  -- Se falhar, a busca segue com o padrão 0.6 em vez de quebrar.
  BEGIN
    PERFORM word_similarity('', '');
    PERFORM set_config('pg_trgm.word_similarity_threshold', '0.5', true);
    PERFORM set_config('pg_trgm.strict_word_similarity_threshold', '0.3', true);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Normaliza: sem acento, minúsculo, pontuação -> espaço, espaços simples
  v_full := btrim(regexp_replace(lower(public.f_unaccent(coalesce(p_q, ''))), '[^a-z0-9]+', ' ', 'g'));
  IF length(v_full) < 2 THEN
    RETURN;
  END IF;
  v_q := ' ' || v_full || ' ';

  -- Sinônimos (termos mais longos primeiro): viram um grupo {termo, expansões...}
  FOR v_syn IN
    SELECT s.term, s.expansions FROM public.search_synonyms s
    WHERE v_q LIKE '% ' || s.term || ' %'
    ORDER BY length(s.term) DESC
  LOOP
    IF v_q LIKE '% ' || v_syn.term || ' %' THEN
      v_groups := v_groups || jsonb_build_array(to_jsonb(array_prepend(v_syn.term, v_syn.expansions)));
      v_q := replace(v_q, ' ' || v_syn.term || ' ', ' ');
    END IF;
  END LOOP;

  -- Palavras restantes (sem stopwords, 2+ caracteres) viram grupos de uma alternativa
  FOR v_tok IN
    SELECT t FROM regexp_split_to_table(btrim(v_q), ' ') t
    WHERE length(t) >= 2
      AND t NOT IN ('de','da','do','das','dos','em','no','na','nos','nas','para','pra','com',
                    'um','uma','os','as','ao','aos','ou','que','eu','me','mim','meu','minha',
                    'quero','queria','gostaria','fazer','estudar','cursar','procuro','busco',
                    'preciso','onde','como','qual','quais','tem','ter','perto','sobre',
                    'curso','cursos','faculdade','graduacao','bacharelado','licenciatura')
  LOOP
    v_groups := v_groups || jsonb_build_array(jsonb_build_array(v_tok));
  END LOOP;

  IF jsonb_array_length(v_groups) = 0 THEN
    RETURN;
  END IF;

  -- Monta condição e relevância de cada grupo
  FOR v_group IN SELECT jsonb_array_elements(v_groups) LOOP
    v_alt_conds := '{}';
    v_alt_ranks := '{}';
    v_group_exact := false;
    FOR v_alt IN SELECT jsonb_array_elements_text(v_group) LOOP
      IF position(' ' IN v_alt) > 0 THEN
        -- frase: precisa aparecer inteira
        v_alt_conds := v_alt_conds || format('v.search_text ILIKE %L', '%' || v_alt || '%');
        v_group_exact := true;
      ELSIF length(v_alt) <= 2 THEN
        -- sigla/UF: só palavra inteira. O search_text do ProUni não tem a UF, mas a
        -- location ("Cidade, UF") tem; por isso a sigla é procurada nas duas.
        v_alt_conds := v_alt_conds || format('(v.search_text || '' '' || coalesce(v.location, '''')) ~* %L',
                                             '\m' || v_alt || '\M');
        v_group_exact := true;
      ELSE
        -- Palavra existe no catálogo? Usa casamento exato (indexado e preciso).
        -- Senão (erro de digitação), usa similaridade de palavra. Não combinar os dois
        -- com OR: o planner abandona o índice e varre a matview inteira.
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.v_unified_opportunities v WHERE v.search_text ILIKE %L)',
                       '%' || v_alt || '%')
          INTO v_exists;
        IF v_exists THEN
          v_alt_conds := v_alt_conds || format('v.search_text ILIKE %L', '%' || v_alt || '%');
          v_group_exact := true;
        ELSE
          EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.v_unified_opportunities v WHERE %L <%% v.search_text)', v_alt)
            INTO v_exists;
          IF v_exists THEN
            v_alt_conds := v_alt_conds || format('%L <%% v.search_text', v_alt);
          ELSE
            -- Erro forte (letra faltando em palavra curta: "mdcina"): candidatos pelo
            -- índice com similaridade estrita baixa (0.3) e confirmação por distância de
            -- edição contra cada palavra do documento (1 letra até 4, 2 até 8, 3 acima).
            v_max_dist := CASE WHEN length(v_alt) <= 4 THEN 1 WHEN length(v_alt) <= 8 THEN 2 ELSE 3 END;
            v_alt_conds := v_alt_conds || format(
              '(%1$L <<%% v.search_text AND EXISTS (SELECT 1 FROM regexp_split_to_table(lower(v.search_text), ''[^a-z0-9]+'') w
                 WHERE abs(length(w) - %2$s) <= %3$s AND public.levenshtein(%1$L, w) <= %3$s))',
              v_alt, length(v_alt), v_max_dist);
          END IF;
        END IF;
      END IF;
      v_alt_ranks := v_alt_ranks
        || format('word_similarity(%L, v.search_text) + word_similarity(%L, lower(public.f_unaccent(v.title)))', v_alt, v_alt);
    END LOOP;
    IF v_group_exact THEN
      v_conds := v_conds || ('(' || array_to_string(v_alt_conds, ' OR ') || ')');
    ELSE
      v_fuzzy_conds := v_fuzzy_conds || ('(' || array_to_string(v_alt_conds, ' OR ') || ')');
    END IF;
    v_ranks := v_ranks || ('GREATEST(' || array_to_string(v_alt_ranks, ', ') || ')');
  END LOOP;

  -- Relaxamento: mantém cada palavra só se ainda houver resultado com ela. A palavra que
  -- zeraria a busca é ignorada no filtro (mas continua pesando na relevância). Assim
  -- "engenharia civil campinas" sem curso em Campinas ainda traz Engenharia Civil.
  -- Palavras com casamento exato entram primeiro; as aproximadas (erro de digitação) por
  -- último, para que uma aproximação ruim nunca expulse uma palavra real.
  FOREACH v_cond IN ARRAY v_conds || v_fuzzy_conds LOOP
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.v_unified_opportunities v WHERE '
            || array_to_string(v_kept || v_cond, ' AND ') || ')'
      INTO v_exists;
    IF v_exists THEN
      v_kept := v_kept || v_cond;
    END IF;
  END LOOP;

  IF cardinality(v_kept) = 0 THEN
    RETURN;
  END IF;
  v_where := array_to_string(v_kept, ' AND ');

  -- Relevância: soma por grupo + bônus quando o título é parecido com a consulta inteira
  -- (faz "medicina" trazer MEDICINA antes de MEDICINA VETERINÁRIA)
  v_select := format(
    'SELECT v.*,
       CASE WHEN %1$L::double precision IS NOT NULL AND %2$L::double precision IS NOT NULL
                 AND v.latitude IS NOT NULL AND v.longitude IS NOT NULL THEN
         6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
           cos(radians(%1$L::double precision)) * cos(radians(v.latitude)) *
           cos(radians(v.longitude) - radians(%2$L::double precision)) +
           sin(radians(%1$L::double precision)) * sin(radians(v.latitude)))))
       END AS distance_km,
       (%3$s + 2 * similarity(%4$L, lower(public.f_unaccent(v.title))))::real AS search_rank
     FROM public.v_unified_opportunities v
     WHERE ',
    p_lat, p_long, array_to_string(v_ranks, ' + '), v_full);

  RETURN QUERY EXECUTE v_select || v_where || ' ORDER BY search_rank DESC, v.unified_id';
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_opportunities_v2(text, double precision, double precision)
  TO anon, authenticated, service_role;

-- =============================================================================
-- Migration: smart_opportunity_search
-- Busca de oportunidades tolerante a acento, caixa, pontuação, ordem das palavras,
-- erros de digitação e apelidos ("adm", "bh", "sampa"), ordenada por relevância.
--
-- Problemas da busca atual (search_opportunities, recriada em 20260828100000):
--   1. LIKE diferencia maiúsculas: search_text dos cursos MEC está em MAIÚSCULAS
--      ("ENFERMAGEM ...") e f_unaccent não converte caixa, então "enfermagem" não
--      encontra nenhum curso MEC.
--   2. Exige a frase exata e contígua: "medicina sao paulo", "direito ufmg" falham.
--   3. Nenhuma tolerância a erro de digitação (word_similarity foi perdido em 20260828).
--   4. search_opportunities_by_distance deixou de existir; o app cai num ilike sem acento.
--
-- Nova RPC search_opportunities_v2(p_q, p_lat, p_long):
--   - normaliza a consulta (f_unaccent + lower + pontuação -> espaço) e remove stopwords;
--   - expande apelidos/sinônimos da tabela search_synonyms (termos de uma ou mais palavras);
--   - cada palavra (ou grupo de sinônimos) precisa casar com o documento, em qualquer ordem:
--     substring (ILIKE) quando a palavra existe no catálogo; senão, similaridade de
--     palavra (pg_trgm <%, limiar 0.5 ajustado em tempo de execução) para tolerar
--     erros de digitação;
--     palavras de 2 letras (UFs, siglas) casam só como palavra inteira;
--   - palavra que zeraria a busca é ignorada no filtro (continua pesando na relevância),
--     então a busca só volta vazia quando nenhuma palavra encontra nada;
--   - devolve search_rank (relevância) e distance_km (quando houver coordenadas).
-- O índice GIN gin_trgm_ops em search_text já existe e atende ILIKE e <% (ambos sem caixa).
-- search_opportunities(p_q) passa a delegar para a v2 (mesmo contrato, ordenado por relevância).
-- =============================================================================

-- 1. Sinônimos / apelidos ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.search_synonyms (
  term        text PRIMARY KEY CHECK (term = lower(term) AND term ~ '^[a-z0-9]+( [a-z0-9]+)*$'),
  expansions  text[] NOT NULL CHECK (cardinality(expansions) > 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.search_synonyms IS
  'Apelidos da busca de oportunidades. term e expansions em minúsculas, sem acento. '
  'Ex.: adm -> {administracao}. O termo original continua valendo como alternativa.';

ALTER TABLE public.search_synonyms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "search_synonyms_select_all" ON public.search_synonyms;
CREATE POLICY "search_synonyms_select_all"
  ON public.search_synonyms FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "search_synonyms_admin_manage" ON public.search_synonyms;
CREATE POLICY "search_synonyms_admin_manage"
  ON public.search_synonyms FOR ALL
  TO authenticated
  USING (public.is_backoffice_admin())
  WITH CHECK (public.is_backoffice_admin());

GRANT SELECT ON public.search_synonyms TO anon, authenticated;

INSERT INTO public.search_synonyms (term, expansions) VALUES
  -- cursos
  ('adm',        '{administracao}'),
  ('ads',        '{analise e desenvolvimento de sistemas}'),
  ('cc',         '{ciencia da computacao}'),
  ('bcc',        '{ciencia da computacao}'),
  ('ti',         '{tecnologia da informacao,sistemas de informacao}'),
  ('si',         '{sistemas de informacao}'),
  ('eng',        '{engenharia}'),
  ('engenheiro', '{engenharia}'),
  ('med',        '{medicina}'),
  ('medico',     '{medicina}'),
  ('vet',        '{veterinaria}'),
  ('veterinario','{veterinaria}'),
  ('odonto',     '{odontologia}'),
  ('dentista',   '{odontologia}'),
  ('fisio',      '{fisioterapia}'),
  ('psico',      '{psicologia}'),
  ('psicologo',  '{psicologia}'),
  ('nutri',      '{nutricao}'),
  ('enfermeiro', '{enfermagem}'),
  ('advogado',   '{direito}'),
  ('edf',        '{educacao fisica}'),
  ('ed fisica',  '{educacao fisica}'),
  ('rh',         '{recursos humanos}'),
  ('rp',         '{relacoes publicas}'),
  ('ri',         '{relacoes internacionais}'),
  ('arq',        '{arquitetura}'),
  ('farma',      '{farmacia}'),
  ('biomed',     '{biomedicina}'),
  ('pedago',     '{pedagogia}'),
  ('contabeis',  '{ciencias contabeis}'),
  ('contabilidade','{ciencias contabeis}'),
  ('eco',        '{economia,ciencias economicas}'),
  ('economia',   '{ciencias economicas}'),
  ('jornalismo', '{comunicacao social}'),
  ('publicidade','{publicidade e propaganda}'),
  -- cidades
  ('bh',         '{belo horizonte}'),
  ('sampa',      '{sao paulo}'),
  ('poa',        '{porto alegre}'),
  ('bsb',        '{brasilia}'),
  ('floripa',    '{florianopolis}'),
  ('ssa',        '{salvador}'),
  ('rio',        '{rio de janeiro}'),
  ('cg',         '{campina grande,campo grande}'),
  -- estados (nome -> UF; a UF está no search_text)
  ('acre','{ac}'), ('alagoas','{al}'), ('amapa','{ap}'), ('amazonas','{am}'),
  ('bahia','{ba}'), ('ceara','{ce}'), ('distrito federal','{df}'),
  ('espirito santo','{es}'), ('goias','{go}'), ('maranhao','{ma}'),
  ('mato grosso','{mt}'), ('mato grosso do sul','{ms}'), ('minas gerais','{mg}'),
  ('minas','{mg}'), ('paraiba','{pb}'), ('parana','{pr}'),
  ('pernambuco','{pe}'), ('piaui','{pi}'), ('rio grande do norte','{rn}'),
  ('rio grande do sul','{rs}'), ('rondonia','{ro}'), ('roraima','{rr}'),
  ('santa catarina','{sc}'), ('sergipe','{se}'), ('tocantins','{to}'),
  ('sao paulo','{sp}'), ('rio de janeiro','{rj}')
ON CONFLICT (term) DO NOTHING;

-- 2. Busca inteligente --------------------------------------------------------------
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
BEGIN
  -- Limiar de similaridade 0.5 (padrão do pg_trgm é 0.6, que perde "medcina", "nutrisao").
  -- Não dá para usar "SET pg_trgm..." na assinatura: em produção o papel das migrations não
  -- pode fixar parâmetro de extensão ainda não carregada (42501). Em tempo de execução,
  -- depois de carregar o pg_trgm, o ajuste é permitido; vale só para esta transação.
  -- Se falhar, a busca segue com o padrão 0.6 em vez de quebrar.
  BEGIN
    PERFORM word_similarity('', '');
    PERFORM set_config('pg_trgm.word_similarity_threshold', '0.5', true);
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
          v_alt_conds := v_alt_conds || format('%L <%% v.search_text', v_alt);
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

-- 3. Contrato antigo delega para a v2 (mesmo retorno, agora ordenado por relevância) --
CREATE OR REPLACE FUNCTION public.search_opportunities(p_q text)
RETURNS SETOF public.v_unified_opportunities
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT v.*
  FROM public.search_opportunities_v2(p_q) s
  JOIN public.v_unified_opportunities v ON v.unified_id = s.unified_id AND v.type = s.type
  ORDER BY s.search_rank DESC, v.unified_id;
$$;
GRANT EXECUTE ON FUNCTION public.search_opportunities(text) TO anon, authenticated, service_role;

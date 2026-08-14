-- TP-5 5b (correção) — card 7410a5bc
--
-- PROBLEMA 1 — a deduplicação entregue no PR #244 não funciona.
--   A Server Action fazia o SELECT de dedupe com a anon key. A policy de leitura
--   de partner_solicitations é restrita a admin:
--       EXISTS (SELECT 1 FROM user_permissions
--               WHERE user_id = auth.uid() AND permission = 'Dashboard')
--   Quem preenche o formulário não está logado: sem auth.uid(), o RLS nega e o
--   SELECT volta vazio SEMPRE. O código concluía "não há duplicado" e inseria.
--   Os testes passavam porque mockavam o retorno do banco — provavam que a
--   lógica reage certo ao que o banco devolve, não que o banco devolve aquilo.
--
-- PROBLEMA 2 — não havia como limitar volume.
--   A policy `Allow public insert` tem WITH CHECK true e não restringe role:
--   qualquer um com a anon key insere quantas linhas quiser, com ou sem
--   formulário na tela.
--
-- CORREÇÃO — uma única porta de entrada.
--   Toda submissão passa a entrar por esta RPC SECURITY DEFINER. Sendo definer,
--   ela enxerga as linhas para deduplicar sem precisar de service_role no app,
--   e nunca devolve dado: só um status.
--
--   O rate limit vive aqui dentro porque o próprio Postgres é o estado
--   compartilhado entre invocações — não é preciso Redis nem WAF para contar
--   quantas tentativas vieram do mesmo IP na última hora.
--
--   A migration seguinte (20260812120100) remove a policy de INSERT público.
--   A partir dela a tabela deixa de ser gravável direto pela anon key, e o
--   limite passa a ser incontornável em vez de apenas presente.

-- ── Tentativas (para throttle) ───────────────────────────────────────────────
-- Tabela separada de propósito: não polui a base de leads, e pode ser purgada
-- sem tocar em dado de negócio. Guarda hash do IP, nunca o IP — endereço IP é
-- dado pessoal, e para contar tentativas o hash basta.
CREATE TABLE IF NOT EXISTS public.partner_solicitation_attempts (
  id         BIGSERIAL PRIMARY KEY,
  ip_hash    TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS partner_solicitation_attempts_ip_time_idx
  ON public.partner_solicitation_attempts (ip_hash, created_at DESC);

CREATE INDEX IF NOT EXISTS partner_solicitation_attempts_time_idx
  ON public.partner_solicitation_attempts (created_at DESC);

-- RLS ligado e SEM policy: ninguém alcança esta tabela a não ser o owner da
-- função definer e o service_role. É contador interno, não dado consultável.
ALTER TABLE public.partner_solicitation_attempts ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.partner_solicitation_attempts IS
'Contador de tentativas de submissão de parceria, por hash de IP, para rate limit dentro de submit_partner_solicitation(). Sem policies: inacessível fora da função definer. Purgado automaticamente a cada chamada.';

-- ── A porta de entrada ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_partner_solicitation(
  p_institution_name TEXT,
  p_contact_name     TEXT,
  p_how_did_you_know TEXT,
  p_whatsapp         TEXT DEFAULT NULL,
  p_email            TEXT DEFAULT NULL,
  p_goals            TEXT DEFAULT NULL,
  p_ip               TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

COMMENT ON FUNCTION public.submit_partner_solicitation(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) IS
'Única porta de entrada para leads de parceria. SECURITY DEFINER para conseguir deduplicar (a policy de leitura é restrita a admin) e para aplicar rate limit por hash de IP usando o próprio banco como estado compartilhado. Devolve apenas status: created | duplicate | rate_limited | invalid. TP-5 5b / card 7410a5bc.';

-- Chamável por visitante anônimo — é um formulário público, esse é o ponto.
-- A proteção não está em quem pode chamar, e sim no que a função aceita fazer.
DO $acl$
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.submit_partner_solicitation(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC';
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.submit_partner_solicitation(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon';
  END IF;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.submit_partner_solicitation(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated';
END
$acl$;

-- 20260707150000_fix_orphan_ead_shift_preference.sql
-- A normalização do shift para 'EaD' (20260707140000) deixou órfãs as preferências de
-- usuário salvas com o rótulo antigo: preferred_shifts = ['Curso a distância'] não casa
-- com nenhuma opportunity → funil do match vazio → 0 matches MEC (7 usuários afetados).
-- A expansão EAD do calculate_match só cobria a direção 'EAD' -> 'Curso a distância'.
--
-- 1. Backfill: substitui 'Curso a distância' por 'EAD' nos preferred_shifts.
-- 2. Defesa bidirecional na função: qualquer variante EAD nas preferências expande para
--    todas ('EAD', 'EaD', 'Curso a distância'), protegendo contra escritas futuras com
--    rótulo antigo e contra dados históricos ainda não normalizados.

-- ====================================================================================
-- 1. Backfill das preferências (duplicatas no array são inofensivas para ANY())
-- ====================================================================================
UPDATE public.user_preferences
SET preferred_shifts = array_replace(preferred_shifts, 'Curso a distância', 'EAD')
WHERE 'Curso a distância' = ANY(preferred_shifts);

-- ====================================================================================
-- 2. calculate_match — expansão EAD bidirecional (única mudança vs 20260707130000):
--    o gatilho passa a incluir 'Curso a distância' presente nas preferências.
--    Trocamos apenas o bloco 1c; o resto da função é reproduzido pela migration
--    anterior e permanece intacto — aqui usamos ALTER-por-recriação apenas do bloco
--    via CREATE OR REPLACE completo NÃO é necessário: fazemos um patch cirúrgico
--    recriando a função a partir da definição vigente com pg_get_functiondef não é
--    suportado em migration estática, então reproduzimos a condição com um wrapper:
--    ATUALIZAÇÃO DIRETA — ver nota abaixo.
-- ====================================================================================
-- NOTA: para manter a migration auto-contida e idempotente sem reproduzir as ~500
-- linhas da função, aplicamos o patch mínimo via DO-block que valida a presença do
-- bloco 1c e o substitui textualmente na definição vigente.
DO $patch$
DECLARE
  v_def text;
  v_old text := $$IF v_preferred_shifts IS NOT NULL
       AND ('EAD' = ANY(v_preferred_shifts) OR 'EaD' = ANY(v_preferred_shifts)) THEN$$;
  v_new text := $$IF v_preferred_shifts IS NOT NULL
       AND ('EAD' = ANY(v_preferred_shifts) OR 'EaD' = ANY(v_preferred_shifts)
            OR 'Curso a distância' = ANY(v_preferred_shifts)) THEN$$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'calculate_match';

  IF position(v_new in v_def) > 0 THEN
    RAISE NOTICE 'calculate_match já contém a expansão bidirecional — nada a fazer.';
    RETURN;
  END IF;

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Bloco 1c não encontrado em calculate_match — definição divergente, patch abortado.';
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$patch$;

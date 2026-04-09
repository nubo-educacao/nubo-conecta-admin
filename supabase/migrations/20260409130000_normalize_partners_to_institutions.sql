-- =============================================================================
-- Sprint 4.5 — Data Normalization: Legacy partners → V1 institutions
-- =============================================================================
-- Problem: migration 20260407170100 created institutions/partner_institutions/
-- partner_opportunities from `partners`, but did NOT remap the FK columns in:
--   • partner_steps        (8 rows  — FK partner_steps_partner_id_fkey → partners)
--   • partner_forms        (43 rows — FK partner_forms_partner_id_fkey → partners)
--   • student_applications (7 rows  — FK student_applications_partner_id_fkey → partners)
--   • external_redirect_clicks     — FK external_redirect_clicks_partner_id_fkey → partners
--
-- Order of operations (critical):
--   1. DROP all four FKs (must happen before any data UPDATE)
--   2. Remap all partner_id values via partners.name → institutions.id
--   3. ADD corrected FKs pointing to institutions
--   4. Enrich partner_opportunities.external_redirect_config with modal fields
--   5. Backfill partner_institutions.location where NULL
--
-- Idempotent: safe to run multiple times.
-- =============================================================================

DO $$
DECLARE
  v_map RECORD;
BEGIN
  RAISE NOTICE '=== Sprint 4.5: Starting partners → institutions normalization ===';

  -- ─── Step 1: Drop all legacy FKs ────────────────────────────────────────────
  -- Must happen before any UPDATE so Postgres does not validate mid-flight values.

  ALTER TABLE public.external_redirect_clicks DROP CONSTRAINT IF EXISTS external_redirect_clicks_partner_id_fkey;
  ALTER TABLE public.partner_steps            DROP CONSTRAINT IF EXISTS partner_steps_partner_id_fkey;
  ALTER TABLE public.partner_forms            DROP CONSTRAINT IF EXISTS partner_forms_partner_id_fkey;
  ALTER TABLE public.student_applications     DROP CONSTRAINT IF EXISTS student_applications_partner_id_fkey;

  RAISE NOTICE 'Step 1 done: all legacy partner_id FKs dropped';

  -- ─── Step 2: Remap partner_id values across all four tables ─────────────────
  -- For each legacy partner, find the matching institution by name and UPDATE.

  FOR v_map IN
    SELECT p.id AS legacy_id, i.id AS institution_id, p.name
    FROM public.partners p
    JOIN public.institutions i ON i.name = p.name
  LOOP
    RAISE NOTICE 'Remapping: % → % (%)', v_map.legacy_id, v_map.institution_id, v_map.name;

    UPDATE public.external_redirect_clicks SET partner_id = v_map.institution_id WHERE partner_id = v_map.legacy_id;
    UPDATE public.partner_steps            SET partner_id = v_map.institution_id WHERE partner_id = v_map.legacy_id;
    UPDATE public.partner_forms            SET partner_id = v_map.institution_id WHERE partner_id = v_map.legacy_id;
    UPDATE public.student_applications     SET partner_id = v_map.institution_id WHERE partner_id = v_map.legacy_id;
  END LOOP;

  -- Null out any remaining unmappable values (safety net)
  UPDATE public.external_redirect_clicks SET partner_id = NULL WHERE partner_id NOT IN (SELECT id FROM public.institutions);
  UPDATE public.partner_steps            SET partner_id = NULL WHERE partner_id NOT IN (SELECT id FROM public.institutions);
  UPDATE public.partner_forms            SET partner_id = NULL WHERE partner_id NOT IN (SELECT id FROM public.institutions);
  UPDATE public.student_applications     SET partner_id = NULL WHERE partner_id NOT IN (SELECT id FROM public.institutions);

  RAISE NOTICE 'Step 2 done: all partner_id values remapped to institutions.id';

  -- ─── Step 3: Add corrected FKs pointing to institutions ─────────────────────

  ALTER TABLE public.external_redirect_clicks
    ADD CONSTRAINT external_redirect_clicks_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.institutions(id) ON DELETE SET NULL;

  ALTER TABLE public.partner_steps
    ADD CONSTRAINT partner_steps_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.institutions(id) ON DELETE CASCADE;

  ALTER TABLE public.partner_forms
    ADD CONSTRAINT partner_forms_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.institutions(id) ON DELETE CASCADE;

  ALTER TABLE public.student_applications
    ADD CONSTRAINT student_applications_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.institutions(id) ON DELETE SET NULL;

  RAISE NOTICE 'Step 3 done: new FKs pointing to institutions added';

  -- ─── Step 4: Enrich external_redirect_config with modal defaults ─────────────
  -- Adds title/message/button_text/type to opportunities that have redirect enabled
  -- but lack the modal UI fields. Does not overwrite existing values.

  UPDATE public.partner_opportunities
  SET external_redirect_config = external_redirect_config || jsonb_build_object(
    'title',       COALESCE(external_redirect_config->>'title',       'Candidatura Externa'),
    'message',     COALESCE(external_redirect_config->>'message',     'A inscrição não é realizada diretamente pela Nubo Conecta. Você será redirecionado para o site da instituição parceira.'),
    'button_text', COALESCE(external_redirect_config->>'button_text', 'Ir para o site'),
    'type',        COALESCE(external_redirect_config->>'type',        'external')
  )
  WHERE (external_redirect_config->>'enabled')::boolean = true;

  RAISE NOTICE 'Step 4 done: external_redirect_config enriched with modal defaults';

  -- ─── Step 5: Backfill partner_institutions.location where NULL ───────────────

  UPDATE public.partner_institutions pi
  SET location = po.eligibility_criteria->>'location'
  FROM public.partner_opportunities po
  WHERE po.institution_id = pi.institution_id
    AND pi.location IS NULL
    AND po.eligibility_criteria->>'location' IS NOT NULL;

  RAISE NOTICE 'Step 5 done: partner_institutions.location backfilled';

  RAISE NOTICE '=== Sprint 4.5: Normalization complete ===';
END $$;

-- ─── Verification (run manually after migration) ─────────────────────────────
-- All should return count = 0:
-- SELECT COUNT(*) FROM partner_steps        WHERE partner_id IN (SELECT id FROM partners);
-- SELECT COUNT(*) FROM partner_forms        WHERE partner_id IN (SELECT id FROM partners);
-- SELECT COUNT(*) FROM student_applications WHERE partner_id IN (SELECT id FROM partners);
-- SELECT COUNT(*) FROM external_redirect_clicks WHERE partner_id IN (SELECT id FROM partners);

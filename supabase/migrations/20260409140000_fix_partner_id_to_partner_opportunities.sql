-- =============================================================================
-- Sprint 4.5 — Semantic fix: partner_id → partner_opportunities.id
-- =============================================================================
-- Problem: after migration 20260409130000, all four tables have partner_id
-- pointing to institutions.id. The correct semantic is partner_opportunities.id:
--   • partner_steps / partner_forms  belong to a specific opportunity's form
--   • student_applications           are applications TO a specific opportunity
--   • external_redirect_clicks       track clicks on a specific opportunity
--
-- Mapping via partner_opportunities.institution_id = current partner_id value.
-- Where an institution has multiple opportunities, the JOIN picks the one whose
-- name matches (fallback: first by created_at).
--
-- Idempotent: DROP IF EXISTS makes it safe to re-run.
-- =============================================================================

DO $$
BEGIN
  RAISE NOTICE '=== Sprint 4.5: Remapping partner_id → partner_opportunities.id ===';

  -- ─── Step 1: Drop current FKs (pointing to institutions) ──────────────────

  ALTER TABLE public.external_redirect_clicks DROP CONSTRAINT IF EXISTS external_redirect_clicks_partner_id_fkey;
  ALTER TABLE public.partner_steps            DROP CONSTRAINT IF EXISTS partner_steps_partner_id_fkey;
  ALTER TABLE public.partner_forms            DROP CONSTRAINT IF EXISTS partner_forms_partner_id_fkey;
  ALTER TABLE public.student_applications     DROP CONSTRAINT IF EXISTS student_applications_partner_id_fkey;

  RAISE NOTICE 'Step 1 done: FKs dropped';

  -- ─── Step 2: Remap data ────────────────────────────────────────────────────
  -- For each row, find the partner_opportunities.id whose institution_id matches
  -- the current partner_id value (which is institutions.id after last migration).
  -- Uses DISTINCT ON (institution_id) ordered by created_at to get a stable pick
  -- when an institution has multiple opportunities.

  -- partner_steps
  UPDATE public.partner_steps ps
  SET partner_id = po.id
  FROM (
    SELECT DISTINCT ON (institution_id) id, institution_id
    FROM public.partner_opportunities
    ORDER BY institution_id, created_at
  ) po
  WHERE ps.partner_id = po.institution_id
    AND ps.partner_id != po.id; -- skip rows already pointing to an opp id

  -- partner_forms
  UPDATE public.partner_forms pf
  SET partner_id = po.id
  FROM (
    SELECT DISTINCT ON (institution_id) id, institution_id
    FROM public.partner_opportunities
    ORDER BY institution_id, created_at
  ) po
  WHERE pf.partner_id = po.institution_id
    AND pf.partner_id != po.id;

  -- student_applications
  UPDATE public.student_applications sa
  SET partner_id = po.id
  FROM (
    SELECT DISTINCT ON (institution_id) id, institution_id
    FROM public.partner_opportunities
    ORDER BY institution_id, created_at
  ) po
  WHERE sa.partner_id = po.institution_id
    AND sa.partner_id != po.id;

  -- external_redirect_clicks
  UPDATE public.external_redirect_clicks erc
  SET partner_id = po.id
  FROM (
    SELECT DISTINCT ON (institution_id) id, institution_id
    FROM public.partner_opportunities
    ORDER BY institution_id, created_at
  ) po
  WHERE erc.partner_id = po.institution_id
    AND erc.partner_id != po.id;

  -- Null out any remaining values not present in partner_opportunities
  UPDATE public.partner_steps        SET partner_id = NULL WHERE partner_id NOT IN (SELECT id FROM public.partner_opportunities);
  UPDATE public.partner_forms        SET partner_id = NULL WHERE partner_id NOT IN (SELECT id FROM public.partner_opportunities);
  UPDATE public.student_applications SET partner_id = NULL WHERE partner_id IS NOT NULL AND partner_id NOT IN (SELECT id FROM public.partner_opportunities);
  UPDATE public.external_redirect_clicks SET partner_id = NULL WHERE partner_id IS NOT NULL AND partner_id NOT IN (SELECT id FROM public.partner_opportunities);

  RAISE NOTICE 'Step 2 done: partner_id values remapped to partner_opportunities.id';

  -- ─── Step 3: Add new FKs pointing to partner_opportunities ────────────────

  ALTER TABLE public.external_redirect_clicks
    ADD CONSTRAINT external_redirect_clicks_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.partner_opportunities(id) ON DELETE SET NULL;

  ALTER TABLE public.partner_steps
    ADD CONSTRAINT partner_steps_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.partner_opportunities(id) ON DELETE CASCADE;

  ALTER TABLE public.partner_forms
    ADD CONSTRAINT partner_forms_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.partner_opportunities(id) ON DELETE CASCADE;

  ALTER TABLE public.student_applications
    ADD CONSTRAINT student_applications_partner_id_fkey
    FOREIGN KEY (partner_id) REFERENCES public.partner_opportunities(id) ON DELETE SET NULL;

  RAISE NOTICE 'Step 3 done: new FKs pointing to partner_opportunities added';

  RAISE NOTICE '=== Sprint 4.5: Remapping complete ===';
END $$;

-- ─── Verification ─────────────────────────────────────────────────────────────
-- All should return count = 0 after migration:
-- SELECT COUNT(*) FROM partner_steps        WHERE partner_id NOT IN (SELECT id FROM partner_opportunities) AND partner_id IS NOT NULL;
-- SELECT COUNT(*) FROM partner_forms        WHERE partner_id NOT IN (SELECT id FROM partner_opportunities) AND partner_id IS NOT NULL;
-- SELECT COUNT(*) FROM student_applications WHERE partner_id NOT IN (SELECT id FROM partner_opportunities) AND partner_id IS NOT NULL;
-- SELECT COUNT(*) FROM external_redirect_clicks WHERE partner_id NOT IN (SELECT id FROM partner_opportunities) AND partner_id IS NOT NULL;

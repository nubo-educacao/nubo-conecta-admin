-- =============================================================================
-- Sprint 3.8 — Data Migration: Legacy partners → V1 Schema
-- =============================================================================
-- Migrates data from the V0 'partners' table into:
--   1. institutions (with is_partner = true)
--   2. partner_institutions (description, cover_url, location)
--   3. partner_opportunities (one per partner, preserving eligibility/redirect data)
--
-- SAFETY: Idempotent — checks for existing rows before insert.
-- TARGET: Run on nubo-hub (dev) first. Prod requires human approval.
-- =============================================================================

DO $$
DECLARE
  rec RECORD;
  v_institution_id UUID;
  v_opp_type VARCHAR;
  v_existing_id UUID;
BEGIN
  RAISE NOTICE '=== Sprint 3.8 Migration: Starting V0 → V1 partners migration ===';

  FOR rec IN
    SELECT
      p.id AS legacy_id,
      p.name,
      p.description,
      p.location,
      p.type,
      p.income,
      p.dates,
      p.link,
      p.coverimage,
      p.external_redirect_config
    FROM public.partners p
    ORDER BY p.created_at
  LOOP
    RAISE NOTICE 'Migrating partner: % (legacy_id: %)', rec.name, rec.legacy_id;

    -- 1. Check if institution already exists by name
    SELECT id INTO v_existing_id
    FROM public.institutions
    WHERE name = rec.name
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      -- Update existing institution to be a partner
      UPDATE public.institutions SET is_partner = true WHERE id = v_existing_id;
      v_institution_id := v_existing_id;
      RAISE NOTICE '  → Found existing institution, set is_partner=true: %', v_institution_id;
    ELSE
      -- Create new institution
      INSERT INTO public.institutions (name, is_partner)
      VALUES (rec.name, true)
      RETURNING id INTO v_institution_id;
      RAISE NOTICE '  → Created new institution: %', v_institution_id;
    END IF;

    -- 2. Upsert into partner_institutions (PK is institution_id)
    INSERT INTO public.partner_institutions (institution_id, description, cover_url, location)
    VALUES (
      v_institution_id,
      rec.description,
      CASE WHEN rec.coverimage IS NOT NULL AND rec.coverimage != '' THEN rec.coverimage ELSE NULL END,
      rec.location
    )
    ON CONFLICT (institution_id) DO UPDATE SET
      description = EXCLUDED.description,
      cover_url   = COALESCE(EXCLUDED.cover_url, public.partner_institutions.cover_url),
      location    = COALESCE(EXCLUDED.location, public.partner_institutions.location);

    RAISE NOTICE '  → partner_institutions upserted';

    -- 3. Determine opportunity_type mapping
    v_opp_type := 'bolsa'; -- default
    IF rec.type IS NOT NULL THEN
      IF LOWER(rec.type) LIKE '%bootcamp%' THEN
        v_opp_type := 'bootcamp';
      ELSIF LOWER(rec.type) LIKE '%mentoria%' THEN
        v_opp_type := 'mentoria';
      END IF;
    END IF;

    -- 4. Create one partner_opportunity per legacy partner (skip if exists with same name+institution)
    IF NOT EXISTS (
      SELECT 1 FROM public.partner_opportunities
      WHERE institution_id = v_institution_id AND name = rec.name
    ) THEN
      INSERT INTO public.partner_opportunities (
        institution_id,
        name,
        description,
        opportunity_type,
        eligibility_criteria,
        external_redirect_config,
        status
      ) VALUES (
        v_institution_id,
        rec.name,
        rec.description,
        v_opp_type,
        jsonb_build_object(
          'location', COALESCE(rec.location, ''),
          'income',   COALESCE(rec.income, ''),
          'type',     COALESCE(rec.type, ''),
          'dates',    COALESCE(rec.dates, '[]'::jsonb)
        ),
        CASE
          WHEN rec.external_redirect_config IS NOT NULL THEN rec.external_redirect_config
          WHEN rec.link IS NOT NULL AND rec.link != '' THEN jsonb_build_object('enabled', true, 'url', rec.link)
          ELSE '{}'::jsonb
        END,
        'approved'
      );
      RAISE NOTICE '  → partner_opportunity created (type: %)', v_opp_type;
    ELSE
      RAISE NOTICE '  → partner_opportunity already exists, skipping';
    END IF;
  END LOOP;

  RAISE NOTICE '=== Sprint 3.8 Migration: Complete ===';
END $$;

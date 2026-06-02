-- Migration: fix foreign key constraint for user_favorites.partner_opportunities_id
-- Previously, partner_id was renamed to partner_opportunities_id but the FK remained linked to partners(id).
-- This migration updates the constraint to link correctly to partner_opportunities(id).

ALTER TABLE user_favorites
  DROP CONSTRAINT IF EXISTS user_favorites_partner_id_fkey;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 
        FROM information_schema.table_constraints 
        WHERE constraint_name = 'user_favorites_partner_opportunities_id_fkey'
        AND table_name = 'user_favorites'
    ) THEN
        ALTER TABLE user_favorites
          ADD CONSTRAINT user_favorites_partner_opportunities_id_fkey 
          FOREIGN KEY (partner_opportunities_id) 
          REFERENCES partner_opportunities(id) 
          ON DELETE CASCADE;
    END IF;
END $$;

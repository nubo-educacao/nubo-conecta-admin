-- fix_partners_users_fk_to_partner_institutions.sql
-- ===================================================
-- Fix partners_users.partner_id foreign key to reference partner_institutions instead of partner_opportunities.
-- partner_opportunities are job opportunities, not partner institutions.
-- partners_users should link users to partner institutions (the actual partner metadata/profile).

-- Drop the incorrect foreign key
ALTER TABLE "public"."partners_users"
DROP CONSTRAINT "partners_users_partner_id_fkey";

-- Add correct foreign key pointing to partner_institutions
ALTER TABLE "public"."partners_users"
ADD CONSTRAINT "partners_users_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_institutions"("institution_id") ON DELETE CASCADE;

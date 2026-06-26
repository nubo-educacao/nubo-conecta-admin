-- fix_partners_users_foreign_key.sql
-- ====================================
-- Fix partners_users.partner_id to reference partner_opportunities instead of legacy partners table.
-- This allows users to be linked to partner_opportunities instead of the legacy partners table.

-- Delete user records that reference non-existent partner_opportunities
DELETE FROM "public"."partners_users" pu
WHERE NOT EXISTS (
  SELECT 1 FROM "public"."partner_opportunities" po
  WHERE po.id = pu.partner_id
);

-- Drop the old foreign key constraint
ALTER TABLE "public"."partners_users"
DROP CONSTRAINT "partners_users_partner_id_fkey";

-- Add new foreign key constraint pointing to partner_opportunities
ALTER TABLE "public"."partners_users"
ADD CONSTRAINT "partners_users_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;

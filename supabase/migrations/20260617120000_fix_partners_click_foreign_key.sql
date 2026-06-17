-- fix_partners_click_foreign_key.sql
-- =====================================
-- Fix partners_click.partner_id to reference partner_opportunities instead of legacy partners table.
-- This allows the vw_partner_funnel view to correctly count partner clicks.
-- Note: Some partner_id values in partners_click reference the legacy 'partners' table,
-- not 'partner_opportunities'. We delete these orphaned records first.

-- Delete click records that reference non-existent partner_opportunities
DELETE FROM "public"."partners_click" pc
WHERE NOT EXISTS (
  SELECT 1 FROM "public"."partner_opportunities" po
  WHERE po.id = pc.partner_id
);

-- Drop the old foreign key constraint
ALTER TABLE "public"."partners_click"
DROP CONSTRAINT "partners_click_partner_id_fkey";

-- Add new foreign key constraint pointing to partner_opportunities
ALTER TABLE "public"."partners_click"
ADD CONSTRAINT "partners_click_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id");

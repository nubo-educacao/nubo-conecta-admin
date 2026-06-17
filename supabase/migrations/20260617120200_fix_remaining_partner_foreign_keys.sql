-- fix_remaining_partner_foreign_keys.sql
-- ========================================
-- Fix remaining foreign keys that reference legacy partners table instead of partner_opportunities.
-- Tables to fix: external_redirect_clicks, knowledge_documents, partner_forms, partner_steps

-- Step 1: Delete orphaned records in tables that reference legacy partners
DELETE FROM "public"."external_redirect_clicks" er
WHERE NOT EXISTS (
  SELECT 1 FROM "public"."partner_opportunities" po
  WHERE po.id = er.partner_id
);

DELETE FROM "public"."knowledge_documents" kd
WHERE NOT EXISTS (
  SELECT 1 FROM "public"."partner_opportunities" po
  WHERE po.id = kd.partner_id
);

DELETE FROM "public"."partner_forms" pf
WHERE NOT EXISTS (
  SELECT 1 FROM "public"."partner_opportunities" po
  WHERE po.id = pf.partner_id
);

DELETE FROM "public"."partner_steps" ps
WHERE NOT EXISTS (
  SELECT 1 FROM "public"."partner_opportunities" po
  WHERE po.id = ps.partner_id
);

-- Step 2: Drop old foreign key constraints
ALTER TABLE "public"."external_redirect_clicks"
DROP CONSTRAINT "external_redirect_clicks_partner_id_fkey";

ALTER TABLE "public"."knowledge_documents"
DROP CONSTRAINT "knowledge_documents_partner_id_fkey";

ALTER TABLE "public"."partner_forms"
DROP CONSTRAINT "partner_forms_partner_id_fkey";

ALTER TABLE "public"."partner_steps"
DROP CONSTRAINT "partner_steps_partner_id_fkey";

-- Step 3: Add new foreign key constraints pointing to partner_opportunities
ALTER TABLE "public"."external_redirect_clicks"
ADD CONSTRAINT "external_redirect_clicks_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id");

ALTER TABLE "public"."knowledge_documents"
ADD CONSTRAINT "knowledge_documents_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE SET NULL;

ALTER TABLE "public"."partner_forms"
ADD CONSTRAINT "partner_forms_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;

ALTER TABLE "public"."partner_steps"
ADD CONSTRAINT "partner_steps_partner_id_fkey"
FOREIGN KEY ("partner_id") REFERENCES "public"."partner_opportunities"("id") ON DELETE CASCADE;

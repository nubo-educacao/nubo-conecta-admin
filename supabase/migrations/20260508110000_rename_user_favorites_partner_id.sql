-- Migration: rename user_favorites.partner_id → partner_opportunities_id
-- Alinha o nome da coluna com a FK real para a tabela partner_opportunities.

ALTER TABLE user_favorites
  RENAME COLUMN partner_id TO partner_opportunities_id;

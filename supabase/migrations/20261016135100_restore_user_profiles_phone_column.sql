-- Reconciliação incremental do DEV com o schema canônico (Sprint 9.0, integração).
--
-- user_profiles.phone faz parte do schema de produção (production_baseline.sql,
-- coluna 33: text, nullable, sem default), mas o DEV foi montado sem ela. Desde
-- 2026-07-29 get_students_paginated lê COALESCE(p.phone, au.phone); sem a coluna,
-- Estudantes falha no DEV com 42703.
--
-- Contrato apurado em 2026-10-16 (somente leitura):
-- * nenhum app (admin, app, cloudinha) nem trigger escreve user_profiles.phone;
-- * em produção a coluna existe e está nula em todas as linhas;
-- * a fonte efetiva do telefone é auth.users.phone (o COALESCE cai nela).
--
-- Por isso só a estrutura é restaurada. Nenhum telefone é preenchido ou copiado.
-- Em produção, onde a coluna já existe, isto não faz nada.

ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS phone text;

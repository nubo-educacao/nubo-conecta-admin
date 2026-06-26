-- Migration: Remove DB triggers for calculate-match-v3 Edge Function
-- Sprint 15 — Decouple match engine calculation from database triggers (explicit frontend execution)
-- Drops the automatic trigger executions so calculations are only done explicitly by frontend calls.

-- 1. Drop trigger on user_preferences
DROP TRIGGER IF EXISTS after_preferences_upsert_enqueue_match_v3 ON public.user_preferences;

-- 2. Drop trigger on user_enem_scores
DROP TRIGGER IF EXISTS after_enem_scores_upsert_enqueue_match_v3 ON public.user_enem_scores;

-- 3. Drop trigger function
DROP FUNCTION IF EXISTS public.trg_enqueue_calculate_match_v3();

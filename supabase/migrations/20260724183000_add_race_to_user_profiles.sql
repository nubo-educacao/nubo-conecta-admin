-- Migration: Add race column to user_profiles table
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS race TEXT;

-- Add school_type column to user_profiles

ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS school_type text;

NOTIFY pgrst, 'reload schema';

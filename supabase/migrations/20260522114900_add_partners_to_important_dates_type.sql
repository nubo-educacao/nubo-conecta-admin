-- Add 'partners' to the allowed types in important_dates
ALTER TABLE public.important_dates DROP CONSTRAINT IF EXISTS important_dates_type_check;
ALTER TABLE public.important_dates ADD CONSTRAINT important_dates_type_check CHECK (type = ANY (ARRAY['sisu'::text, 'prouni'::text, 'general'::text, 'partners'::text]));

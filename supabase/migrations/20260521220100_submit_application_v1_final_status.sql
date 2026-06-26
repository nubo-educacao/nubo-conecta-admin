-- Card 9.3.3 T5: Add 3-param overload of submit_application_v1 with p_final_status.
-- The existing 2-param version continues to work (backward-compatible).

CREATE OR REPLACE FUNCTION public.submit_application_v1(
  p_application_id UUID,
  p_answers        JSONB,
  p_final_status   TEXT DEFAULT 'SUBMITTED'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_caller  UUID := auth.uid();
BEGIN
  -- Validate final status
  IF p_final_status NOT IN ('SUBMITTED', 'redirected', 'pending') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid final status');
  END IF;

  SELECT user_id INTO v_user_id
  FROM student_applications
  WHERE id = p_application_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Application not found');
  END IF;

  IF v_user_id <> v_caller THEN
    IF NOT EXISTS (
      SELECT 1 FROM user_profiles
      WHERE id = v_user_id AND parent_user_id = v_caller
    ) THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unauthorized');
    END IF;
  END IF;

  UPDATE student_applications
  SET
    answers    = COALESCE(answers, '{}'::jsonb) || p_answers,
    status     = p_final_status,
    updated_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('success', true, 'application_id', p_application_id);
END;
$$;

-- Drop old 2-param signature since CREATE OR REPLACE with different params creates a new overload
-- We need to drop the old one to avoid ambiguity
DROP FUNCTION IF EXISTS public.submit_application_v1(UUID, JSONB);

-- Grant on new signature
REVOKE ALL ON FUNCTION public.submit_application_v1(UUID, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_application_v1(UUID, JSONB, TEXT) TO authenticated;

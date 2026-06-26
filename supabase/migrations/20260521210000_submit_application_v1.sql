-- Finalizes a student application: merges answers and transitions status to SUBMITTED.
-- RLS: caller must be the application owner OR the parent of the owner (dependent profile).

CREATE OR REPLACE FUNCTION public.submit_application_v1(
  p_application_id UUID,
  p_answers        JSONB
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
  -- Resolve the application owner
  SELECT user_id INTO v_user_id
  FROM student_applications
  WHERE id = p_application_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Application not found');
  END IF;

  -- Authorization: caller is the owner OR the parent of the owner (dependent profile)
  IF v_user_id <> v_caller THEN
    IF NOT EXISTS (
      SELECT 1 FROM user_profiles
      WHERE id = v_user_id AND parent_user_id = v_caller
    ) THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unauthorized');
    END IF;
  END IF;

  -- Merge final answers and mark as submitted
  UPDATE student_applications
  SET
    answers    = COALESCE(answers, '{}'::jsonb) || p_answers,
    status     = 'SUBMITTED',
    updated_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('success', true, 'application_id', p_application_id);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_application_v1(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_application_v1(UUID, JSONB) TO authenticated;

-- Migration: Fix Admin update policy to use correct is_backoffice_admin function (V3)
-- The V2 migration used a hardcoded permission check ('admin') which doesn't exist in user_permissions.

DROP POLICY IF EXISTS "student_applications_admin_update" ON public.student_applications;

CREATE POLICY "student_applications_admin_update"
ON public.student_applications
FOR UPDATE
USING (public.is_backoffice_admin());

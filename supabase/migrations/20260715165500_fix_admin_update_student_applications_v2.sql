-- Migration: Add policy for admin to update student_applications (V2)
-- The previous migration failed on prod due to a syntax error but was marked as applied.

DROP POLICY IF EXISTS "student_applications_admin_update" ON public.student_applications;

CREATE POLICY "student_applications_admin_update"
ON public.student_applications
FOR UPDATE
USING (EXISTS (SELECT 1 FROM public.user_permissions WHERE user_id = auth.uid() AND permission = 'admin'));

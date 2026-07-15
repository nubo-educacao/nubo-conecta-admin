-- Migration: Add policy for partners to update student_applications

DROP POLICY IF EXISTS "student_applications_partner_update" ON public.student_applications;

CREATE POLICY "student_applications_partner_update"
ON public.student_applications
FOR UPDATE
USING (
  partner_id IN (
    SELECT po.id 
    FROM public.partner_opportunities po 
    JOIN public.partners_users pu ON pu.partner_id = po.institution_id 
    WHERE pu.user_id = auth.uid()
  )
);

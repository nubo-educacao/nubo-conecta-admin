-- Migration: Fix student_applications SELECT policies

-- 1. Fix the partner SELECT policy (it was incorrectly comparing opportunity_id with institution_id)
DROP POLICY IF EXISTS "student_applications_select_partner" ON public.student_applications;

CREATE POLICY "student_applications_select_partner"
ON public.student_applications
FOR SELECT
USING (
  partner_id IN (
    SELECT po.id 
    FROM public.partner_opportunities po 
    JOIN public.partners_users pu ON pu.partner_id = po.institution_id 
    WHERE pu.user_id = auth.uid()
  )
);

-- 2. Create the missing admin SELECT policy
DROP POLICY IF EXISTS "student_applications_select_admin" ON public.student_applications;

CREATE POLICY "student_applications_select_admin"
ON public.student_applications
FOR SELECT
USING (
  public.is_backoffice_admin()
);

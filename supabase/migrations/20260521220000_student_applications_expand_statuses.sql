-- Card 9.3.3: Expand student_applications statuses for redirect + submitted flows.

ALTER TABLE public.student_applications
  DROP CONSTRAINT IF EXISTS student_applications_status_check;

ALTER TABLE public.student_applications
  ADD CONSTRAINT student_applications_status_check
    CHECK (status IN (
      'started', 'eligible', 'ineligible', 'submitted',
      'DRAFT', 'pending', 'SUBMITTED', 'redirected',
      'ELIGIBLE', 'INELIGIBLE', 'IN_REVIEW', 'APPROVED', 'REJECTED'
    ));

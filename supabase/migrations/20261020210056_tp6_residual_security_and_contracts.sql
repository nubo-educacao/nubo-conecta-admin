-- TP-6 authorized residual. Forward-only; no production application in this task.
CREATE OR REPLACE FUNCTION public.get_backoffice_users()
RETURNS TABLE(id uuid, email text, permissions text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT u.id, u.email::text, array_agg(up.permission ORDER BY up.permission)
    FROM auth.users u JOIN public.user_permissions up ON up.user_id=u.id GROUP BY u.id,u.email;
END;
$$;
REVOKE ALL ON FUNCTION public.get_backoffice_users() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_backoffice_users() TO authenticated, service_role;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='partner') THEN
    REVOKE ALL ON FUNCTION public.get_backoffice_users() FROM partner;
  END IF;
END $$;

-- Separate name avoids PostgREST overload ambiguity for the existing UUID-only API.
CREATE OR REPLACE FUNCTION public.get_student_matches_admin_page(
  p_profile_id uuid, p_page integer DEFAULT 0, p_page_size integer DEFAULT 20
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_count bigint; v_matches json;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  IF p_profile_id IS NULL OR p_page IS NULL OR p_page < 0 OR p_page_size IS NULL OR p_page_size < 1 OR p_page_size > 100 THEN
    RAISE EXCEPTION 'paginação inválida' USING ERRCODE = '22023';
  END IF;
  SELECT count(*) INTO v_count FROM public.user_opportunity_matches WHERE profile_id=p_profile_id;
  SELECT coalesce(json_agg(t), '[]'::json) INTO v_matches FROM (
    SELECT m.unified_opportunity_id,m.match_score,m.match_details,
      coalesce(v.title,'Oportunidade') AS title,coalesce(v.provider_name,'-') AS provider_name
    FROM public.user_opportunity_matches m
    LEFT JOIN public.v_unified_opportunities v ON v.unified_id=m.unified_opportunity_id
    WHERE m.profile_id=p_profile_id
    ORDER BY m.match_score DESC NULLS LAST,m.unified_opportunity_id,m.id
    LIMIT p_page_size OFFSET (p_page::bigint * p_page_size)
  ) t;
  RETURN json_build_object('count',v_count,'matches',v_matches,'page',p_page,'page_size',p_page_size);
END;
$$;
CREATE OR REPLACE FUNCTION public.get_student_matches_admin(p_profile_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN public.get_student_matches_admin_page(p_profile_id,0,20);
END;
$$;
REVOKE ALL ON FUNCTION public.get_student_matches_admin(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_student_matches_admin_page(uuid,integer,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_student_matches_admin(uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_student_matches_admin_page(uuid,integer,integer) TO authenticated,service_role;

-- Deliberately retain an owner-executed view with an explicit authorization
-- predicate: profile RLS permits self/admin but cannot supply partner names.
-- Institution membership uses po.institution_id, never the opportunity id.
CREATE OR REPLACE VIEW public.vw_partner_application_details WITH (security_barrier=true) AS
SELECT sa.id AS application_id,sa.partner_id,sa.user_id,up.full_name AS student_name,
  sa.status,sa.created_at,sa.updated_at,
  (SELECT count(*) FROM jsonb_object_keys(
    CASE WHEN jsonb_typeof(sa.answers)='object' THEN sa.answers ELSE '{}'::jsonb END)) AS total_answers_filled
FROM public.student_applications sa JOIN public.user_profiles up ON up.id=sa.user_id
WHERE auth.uid() IS NOT NULL AND (
  public.is_backoffice_admin()
  OR EXISTS (SELECT 1 FROM public.user_permissions p WHERE p.user_id=auth.uid() AND p.permission='Parceiros')
  OR EXISTS (SELECT 1 FROM public.partner_opportunities po
    JOIN public.partners_users pu ON pu.partner_id=po.institution_id
    WHERE po.id=sa.partner_id AND pu.user_id=auth.uid())
);
-- Both layers use the scoped detail view; no privileged unfiltered inner view.
CREATE OR REPLACE VIEW public.vw_partner_application_completion_buckets WITH (security_barrier=true) AS
WITH partner_form_counts AS (
  SELECT partner_id,count(*) AS total_forms FROM public.partner_forms GROUP BY partner_id
), application_percentages AS (
  SELECT a.partner_id,
    CASE WHEN a.status='SUBMITTED' THEN 100
      WHEN coalesce(fc.total_forms,0)=0 THEN 0
      ELSE least(100,a.total_answers_filled*100/fc.total_forms) END AS completion_percent
  FROM public.vw_partner_application_details a LEFT JOIN partner_form_counts fc ON fc.partner_id=a.partner_id
)
SELECT partner_id,CASE WHEN completion_percent<=25 THEN '1. Até 25%'
  WHEN completion_percent<=50 THEN '2. Até 50%' WHEN completion_percent<=75 THEN '3. Até 75%'
  ELSE '4. Até 100%' END AS completion_bucket,count(*) AS applications_count
FROM application_percentages GROUP BY partner_id,completion_bucket;
REVOKE ALL ON public.vw_partner_application_details,public.vw_partner_application_completion_buckets FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.vw_partner_application_details,public.vw_partner_application_completion_buckets TO authenticated,service_role;

-- Repair DEV drift without editing the applied historical migration or deleting orphans.
DO $$
DECLARE v_constraint name;
BEGIN
  SELECT conname INTO v_constraint FROM pg_constraint
    WHERE conrelid='public.user_favorites'::regclass AND confrelid='public.courses'::regclass AND contype='f'
      AND conkey=ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid='public.user_favorites'::regclass AND attname='course_id')]
    LIMIT 1;
  IF v_constraint IS NULL THEN
    ALTER TABLE public.user_favorites ADD CONSTRAINT user_favorites_course_id_fkey
      FOREIGN KEY(course_id) REFERENCES public.courses(id) ON DELETE CASCADE NOT VALID;
    v_constraint := 'user_favorites_course_id_fkey';
  END IF;
  EXECUTE format('ALTER TABLE public.user_favorites VALIDATE CONSTRAINT %I',v_constraint);
END $$;

CREATE OR REPLACE FUNCTION public.get_eligible_count_by_institution(p_institution_id uuid)
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (
    public.is_backoffice_admin()
    OR EXISTS (SELECT 1 FROM public.user_permissions p WHERE p.user_id=auth.uid() AND p.permission='Parceiros')
    OR EXISTS (SELECT 1 FROM public.partners_users pu WHERE pu.user_id=auth.uid() AND pu.partner_id=p_institution_id)
  ) THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT count(DISTINCT sa.user_id)
    FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id=sa.partner_id
    WHERE po.institution_id=p_institution_id
      AND jsonb_typeof(sa.eligibility_results)='array'
      AND jsonb_array_length(CASE WHEN jsonb_typeof(sa.eligibility_results)='array' THEN sa.eligibility_results ELSE '[]'::jsonb END)>0
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(sa.eligibility_results)='array' THEN sa.eligibility_results ELSE '[]'::jsonb END
      ) elem WHERE (elem->>'met')::boolean=false));
END;
$$;
REVOKE ALL ON FUNCTION public.get_eligible_count_by_institution(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_eligible_count_by_institution(uuid) TO authenticated,service_role;

-- The old ALL/true policy is not service-role-scoped despite its name.
-- Correct it before exposing the canonical examples editor.
DROP POLICY IF EXISTS "Service role can manage learning examples" ON public.learning_examples;
CREATE POLICY "Service role can manage learning examples" ON public.learning_examples
  FOR ALL TO service_role USING(true) WITH CHECK(true);
DROP POLICY IF EXISTS "Backoffice can manage learning examples" ON public.learning_examples;
CREATE POLICY "Backoffice can manage learning examples" ON public.learning_examples
  FOR ALL TO authenticated USING(public.is_backoffice_admin()) WITH CHECK(public.is_backoffice_admin());
REVOKE ALL ON public.learning_examples FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.learning_examples TO anon,authenticated;
GRANT INSERT,UPDATE,DELETE ON public.learning_examples TO authenticated;
GRANT ALL ON public.learning_examples TO service_role;

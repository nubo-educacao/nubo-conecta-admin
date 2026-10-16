-- Staging regression: invoker JOIN is hidden by partner_opportunities RLS.
-- The underlying RPC already authorizes every returned opportunity by institution.
ALTER FUNCTION public.get_partner_institution_redirect_users(uuid) SECURITY DEFINER;

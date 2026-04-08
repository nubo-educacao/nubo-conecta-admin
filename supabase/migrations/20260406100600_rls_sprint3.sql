-- 20260406100600_rls_sprint3.sql
-- Sprint 3: RLS para todas as novas tabelas

-- users_metadata: Apenas o próprio usuário (+ dependentes)
ALTER TABLE public.users_metadata ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_metadata_select_own" ON public.users_metadata
    FOR SELECT USING (
        profile_id IN (
            SELECT id FROM public.user_profiles
            WHERE id = auth.uid() OR parent_user_id = auth.uid()
        )
    );
CREATE POLICY "users_metadata_insert_own" ON public.users_metadata
    FOR INSERT WITH CHECK (
        profile_id IN (
            SELECT id FROM public.user_profiles
            WHERE id = auth.uid() OR parent_user_id = auth.uid()
        )
    );
CREATE POLICY "users_metadata_update_own" ON public.users_metadata
    FOR UPDATE USING (
        profile_id IN (
            SELECT id FROM public.user_profiles
            WHERE id = auth.uid() OR parent_user_id = auth.uid()
        )
    );

-- cloudinha_starters: Leitura pública, escrita apenas admin
-- Nota: admin check via is_backoffice_admin() — tabela user_permissions usa coluna 'permission', não 'role'
ALTER TABLE public.cloudinha_starters ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cloudinha_starters_select_all" ON public.cloudinha_starters
    FOR SELECT USING (true);
CREATE POLICY "cloudinha_starters_admin_all" ON public.cloudinha_starters
    FOR ALL USING (public.is_backoffice_admin());

-- match_config: Leitura pública, escrita apenas admin
ALTER TABLE public.match_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "match_config_select_all" ON public.match_config
    FOR SELECT USING (true);
CREATE POLICY "match_config_admin_all" ON public.match_config
    FOR ALL USING (public.is_backoffice_admin());

-- user_opportunity_matches: Apenas o próprio usuário
ALTER TABLE public.user_opportunity_matches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "uom_select_own" ON public.user_opportunity_matches
    FOR SELECT USING (
        profile_id IN (
            SELECT id FROM public.user_profiles
            WHERE id = auth.uid() OR parent_user_id = auth.uid()
        )
    );
CREATE POLICY "uom_insert_own" ON public.user_opportunity_matches
    FOR INSERT WITH CHECK (
        profile_id IN (
            SELECT id FROM public.user_profiles
            WHERE id = auth.uid() OR parent_user_id = auth.uid()
        )
    );
CREATE POLICY "uom_delete_own" ON public.user_opportunity_matches
    FOR DELETE USING (
        profile_id IN (
            SELECT id FROM public.user_profiles
            WHERE id = auth.uid() OR parent_user_id = auth.uid()
        )
    );

-- agent_turns: Leitura por admin apenas (dados sensíveis de telemetria)
ALTER TABLE public.agent_turns ENABLE ROW LEVEL SECURITY;
CREATE POLICY "agent_turns_admin_select" ON public.agent_turns
    FOR SELECT USING (public.is_backoffice_admin());
CREATE POLICY "agent_turns_insert_service" ON public.agent_turns
    FOR INSERT WITH CHECK (true);

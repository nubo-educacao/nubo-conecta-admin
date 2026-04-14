-- Sprint 5.5 Plano D-fix: Adicionar RLS policies de escrita para home_sections
-- O Admin usa authenticated role (anon key com JWT válido de usuário admin)

-- Policy: Admin autenticado pode fazer INSERT
CREATE POLICY "home_sections_insert_authenticated"
  ON public.home_sections
  FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

-- Policy: Admin autenticado pode fazer UPDATE
CREATE POLICY "home_sections_update_authenticated"
  ON public.home_sections
  FOR UPDATE
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- Policy: Admin autenticado pode fazer DELETE
CREATE POLICY "home_sections_delete_authenticated"
  ON public.home_sections
  FOR DELETE
  USING (auth.role() = 'authenticated');

COMMENT ON TABLE public.home_sections
  IS 'CMS dinâmico da Home App. Leitura pública (App), escrita apenas para usuários autenticados (Admin).';

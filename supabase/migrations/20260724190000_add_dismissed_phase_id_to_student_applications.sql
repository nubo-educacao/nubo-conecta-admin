-- 20260724190000_add_dismissed_phase_id_to_student_applications.sql
--
-- O CTA "Processo Seletivo Ativo!" (mudança de fase) usava localStorage
-- (nubo_clicked_banners_{user_id}) para lembrar que o usuário já viu/clicou
-- naquela fase — funciona só naquele navegador/dispositivo, some se o usuário
-- limpar o cache ou logar em outro aparelho. Persiste isso no banco em vez
-- disso: dismissed_phase_id guarda a última fase que o usuário já dispensou
-- (clicou no CTA). O banner reaparece automaticamente quando phase_id muda
-- de novo (nova fase != dismissed_phase_id).

ALTER TABLE public.student_applications
  ADD COLUMN IF NOT EXISTS dismissed_phase_id uuid;

import { beforeEach, expect, it, vi } from 'vitest';
import { getFewShotExamples, updateFewShotExample } from '@/services/fewShotService';
const mocks = vi.hoisted(() => ({ from: vi.fn(), select: vi.fn(), update: vi.fn(), order: vi.fn(), eq: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { from: mocks.from } }));
beforeEach(() => {
  mocks.from.mockReturnValue(mocks);
  mocks.select.mockReturnValue(mocks);
  mocks.order.mockReturnValue(mocks);
  mocks.eq.mockResolvedValue({ error: null });
  mocks.update.mockReturnValue(mocks);
});
it('reads canonical fields without inventing a starter, tools or ordering column', async () => {
  mocks.order.mockResolvedValueOnce({ data: [{ id: '1', intent_category: 'match', input_query: 'Oi', ideal_output: 'Olá', reasoning: null, is_active: true }], error: null });
  const rows = await getFewShotExamples();
  expect(mocks.from).toHaveBeenCalledWith('learning_examples');
  expect(mocks.select).toHaveBeenCalledWith('id,intent_category,input_query,ideal_output,reasoning,source,is_active,created_at');
  expect(rows[0].ideal_output).toBe('Olá');
});
it('updates only canonical editable fields and preserves source/embedding', async () => {
  await updateFewShotExample('1', { ideal_output: 'Nova resposta', reasoning: 'Critério' });
  expect(mocks.update).toHaveBeenCalledWith({ ideal_output: 'Nova resposta', reasoning: 'Critério' });
});

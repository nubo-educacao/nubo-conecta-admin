import { beforeEach, describe, expect, it, vi } from 'vitest';
import { getStudentDetails } from '@/services/studentsService';
const mocks = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: mocks }));
beforeEach(() => {
  mocks.from.mockImplementation((table: string) => {
    const result = table === 'user_favorites'
      ? { data: null, error: { message: 'missing relationship' } }
      : { data: table === 'user_profiles' ? { id: 'student', full_name: 'Ana' } : null, error: null };
    const q: any = { then: (resolve: any) => Promise.resolve(result).then(resolve) };
    for (const method of ['select', 'eq', 'single', 'maybeSingle', 'order']) q[method] = () => q;
    return q;
  });
  mocks.rpc.mockResolvedValue({ data: { matches: [], count: 0 }, error: null });
});
describe('TP6 independent student sources', () => {
  it('preserves profile and matches when the favorites relation fails', async () => {
    const result = await getStudentDetails('student');
    expect(result.profile?.full_name).toBe('Ana');
    expect(result.source_errors?.favorites).toBeTruthy();
    expect(result.source_errors?.matches).toBeUndefined();
    expect(result.matches).toEqual([]);
  });
  it('isolates a rejected request as well as a Supabase error response', async () => {
    mocks.rpc.mockRejectedValueOnce(new Error('offline'));
    const result = await getStudentDetails('student');
    expect(result.profile?.full_name).toBe('Ana');
    expect(result.source_errors?.matches).toBeTruthy();
  });
});

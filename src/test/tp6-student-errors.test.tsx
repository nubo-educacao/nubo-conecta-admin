import { beforeEach, expect, it, vi } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import Students from '@/pages/Students';
import { StudentDetailsModal } from '@/components/students/StudentDetailsModal';
const mocks = vi.hoisted(() => ({ list: vi.fn(), stats: vi.fn(), details: vi.fn() }));
vi.mock('@/services/studentsService', () => ({
  getStudents: mocks.list, getStudentStats: mocks.stats, getStudentDetails: mocks.details,
  importNuboStudents: vi.fn(),
}));
vi.mock('@/hooks/useStudentFilters', () => ({ useStudentFilters: () => ({ filters: {}, setFilters: vi.fn(), clearFilters: vi.fn() }) }));
vi.mock('@/components/students/StudentTable', () => ({ StudentTable: ({students}: any) => <div>{students.length ? 'Lista recuperada' : 'Nenhum estudante encontrado'}</div> }));
vi.mock('@/components/students/StudentStats', () => ({ StudentStats: () => null }));
vi.mock('@/components/students/StudentExportButton', () => ({ StudentExportButton: () => null }));
vi.mock('@/components/students/StudentFilterModal', () => ({ StudentFilterModal: () => null }));
vi.mock('@/components/students/StudentActivityModal', () => ({ StudentActivityModal: () => null }));
beforeEach(() => {
  cleanup(); vi.clearAllMocks();
  mocks.stats.mockResolvedValue({});
});
function mount(element: React.ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={client}>{element}</QueryClientProvider>);
}
it('distinguishes a failed list from empty results and recovers on retry', async () => {
  mocks.list.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ data: [{id:'1'}], count:1 });
  mount(<Students />);
  expect(await screen.findByRole('alert')).toHaveTextContent('Não foi possível carregar os estudantes');
  expect(screen.queryByText('Nenhum estudante encontrado')).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', {name:'Tentar novamente'}));
  expect(await screen.findByText('Lista recuperada')).toBeInTheDocument();
});
it('preserves profile and its tabs when preferences fail, with retry', async () => {
  const details = { profile: {full_name:'Ana'}, preferences:null, enem_scores:[], favorites:[], matches:[], total_matches:0 };
  mocks.details.mockResolvedValueOnce({...details, source_errors:{preferences:'Preferências indisponíveis'}})
    .mockResolvedValueOnce({...details, source_errors:{}});
  mount(<StudentDetailsModal isOpen onOpenChange={vi.fn()} studentId="1" />);
  expect((await screen.findAllByText('Ana'))[0]).toBeInTheDocument();
  expect(screen.getAllByRole('tab')).toHaveLength(2);
  expect(screen.getByRole('alert')).toHaveTextContent('Preferências indisponíveis');
  fireEvent.click(screen.getByRole('button', {name:'Tentar novamente'}));
  await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument());
  expect(screen.getAllByText('Ana')[0]).toBeInTheDocument();
});

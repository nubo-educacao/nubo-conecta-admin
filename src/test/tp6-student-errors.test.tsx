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
it('preserves profile and the three tabs when preferences fail, with retry', async () => {
  const details = { profile: {full_name:'Ana'}, preferences:null, enem_scores:[], favorites:[], matches:[], total_matches:0 };
  mocks.details.mockResolvedValueOnce({...details, source_errors:{preferences:'Preferências indisponíveis'}})
    .mockResolvedValueOnce({...details, source_errors:{}});
  mount(<StudentDetailsModal isOpen onOpenChange={vi.fn()} studentId="1" />);
  expect(await screen.findByText('Ana')).toBeInTheDocument();
  expect(screen.getAllByRole('tab')).toHaveLength(3);
  expect(screen.getByRole('alert')).toHaveTextContent('Preferências indisponíveis');
  fireEvent.click(screen.getByRole('button', {name:'Tentar novamente'}));
  await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument());
  expect(screen.getByText('Ana')).toBeInTheDocument();
});
it('keeps Matches selected when loading the next page', async () => {
  const result = { profile:{full_name:'Ana'}, preferences:null, enem_scores:[], favorites:[],
    matches:[{title:'Curso inicial',provider_name:'IES',match_score:80}],total_matches:25,source_errors:{} };
  mocks.details.mockResolvedValueOnce(result).mockResolvedValueOnce({...result,
    matches:[{title:'Curso seguinte',provider_name:'IES',match_score:70}]});
  mount(<StudentDetailsModal isOpen onOpenChange={vi.fn()} studentId="1" />);
  await screen.findByText('Ana');
  fireEvent.mouseDown(screen.getByRole('tab', {name:/Matchs/}), {button:0,ctrlKey:false});
  expect(await screen.findByText('Curso inicial')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', {name:'Próxima'}));
  expect(await screen.findByText('Curso seguinte')).toBeInTheDocument();
  expect(screen.getByRole('tab', {name:/Matchs/})).toHaveAttribute('data-state','active');
  expect(mocks.details).toHaveBeenLastCalledWith('1',1);
});

import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { StudentActivityModal } from '@/components/students/StudentActivityModal';
import { StudentTable } from '@/components/students/StudentTable';
const mocks = vi.hoisted(() => ({ matches:vi.fn(), clicks:vi.fn(), applications:vi.fn() }));
vi.mock('@/services/studentActivityService', () => ({
  ACTIVITY_PAGE_SIZE:20, getActivityMatches:mocks.matches, getActivityClicks:mocks.clicks,
  getActivityApplications:mocks.applications,
}));
let client:QueryClient;
beforeEach(() => {
  vi.resetAllMocks();
  client = new QueryClient({defaultOptions:{queries:{retry:false,gcTime:Infinity}}});
  mocks.matches.mockResolvedValue({data:[],count:0});
  mocks.clicks.mockResolvedValue({data:[],count:0});
  mocks.applications.mockResolvedValue({data:[],count:0});
});
afterEach(() => {cleanup();client.clear();});
const modal = (id='a',open=true) => <QueryClientProvider client={client}>
  <StudentActivityModal isOpen={open} onOpenChange={vi.fn()} studentId={id} studentName={id} />
</QueryClientProvider>;
function tab(name:string) {
  fireEvent.mouseDown(screen.getByRole('tab',{name}),{button:0,ctrlKey:false});
}
function deferred() {
  let resolve!:(value:any)=>void;
  const promise = new Promise<any>(r => {resolve=r;});
  return {promise,resolve};
}
it('exposes separate actions even for a student with no activity', () => {
  const details=vi.fn(), activity=vi.fn();
  render(<StudentTable students={[{id:'a',full_name:'Ana'} as any]}
    onViewDetails={details} onViewActivity={activity} />);
  fireEvent.click(screen.getByRole('button',{name:'Ver detalhes'}));
  expect(details).toHaveBeenCalledWith(expect.objectContaining({id:'a'}));
  expect(activity).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button',{name:'Ver atividade'}));
  expect(activity).toHaveBeenCalledWith(expect.objectContaining({id:'a'}));
});
it('does not load when closed; lazily loads the selected collection with independent empty states', async () => {
  const view=render(modal('a',false));
  expect(mocks.matches).not.toHaveBeenCalled();
  view.rerender(modal());
  expect(await screen.findByText('Nenhum match encontrado.')).toBeInTheDocument();
  expect(screen.getAllByRole('tab')).toHaveLength(3);
  expect(mocks.clicks).not.toHaveBeenCalled(); expect(mocks.applications).not.toHaveBeenCalled();
  tab('Clicks');
  expect(await screen.findByText('Nenhum click encontrado.')).toBeInTheDocument();
  tab('Candidaturas');
  expect(await screen.findByText('Nenhuma candidatura encontrada.')).toBeInTheDocument();
});
it('renders match details and totals, changes pages without mixing rows, and restores each tab page', async () => {
  mocks.matches.mockImplementation((_id:string,page:number) => Promise.resolve({
    data:[{unified_opportunity_id:'course_'+page,title:'Curso '+page,provider_name:'IES',match_score:84,match_details:{reason:'Compatível'}}],count:21
  }));
  mocks.clicks.mockResolvedValue({data:[{id:'click',entity_name:'Bolsa',event_type:'external_redirect',occurred_at:'2026-10-01',event_count:2}],count:1});
  render(modal());
  expect(await screen.findByText('Curso 0')).toBeInTheDocument();
  expect(screen.getByText('84%')).toBeInTheDocument();
  expect(screen.getByText(/Compatível/)).toBeInTheDocument();
  expect(screen.getByText('Total: 21')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button',{name:'Próxima'}));
  expect(await screen.findByText('Curso 1')).toBeInTheDocument();
  expect(screen.queryByText('Curso 0')).not.toBeInTheDocument();
  expect(screen.getByRole('button',{name:'Próxima'})).toBeDisabled();
  tab('Clicks'); expect(await screen.findByText('Bolsa')).toBeInTheDocument();
  tab('Matches'); expect(await screen.findByText('Curso 1')).toBeInTheDocument();
  expect(mocks.matches).toHaveBeenLastCalledWith('a',1,expect.any(Object));
});
it('keeps other collections usable after one fails and retries that collection only', async () => {
  mocks.clicks.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({data:[],count:0});
  mocks.applications.mockResolvedValue({data:[{id:'app',partner_name:'Bolsa teste',institution_name:'Instituição',status:'SUBMITTED',created_at:'2026-10-01'}],count:1});
  render(modal());
  await screen.findByText('Nenhum match encontrado.');
  tab('Clicks');
  expect(await screen.findByRole('alert')).toHaveTextContent('Não foi possível carregar Clicks');
  tab('Candidaturas');
  expect(await screen.findByText('Bolsa teste')).toBeInTheDocument();
  expect(screen.getByText('Enviada')).toBeInTheDocument();
  tab('Clicks');
  fireEvent.click(await screen.findByRole('button',{name:'Tentar novamente'}));
  expect(await screen.findByText('Nenhum click encontrado.')).toBeInTheDocument();
  expect(mocks.matches).toHaveBeenCalledTimes(1);
  expect(mocks.applications).toHaveBeenCalledTimes(1);
});
it('isolates out-of-order responses across student, tab and page changes', async () => {
  const oldStudent=deferred(), oldClicks=deferred(), oldPage=deferred();
  mocks.matches.mockImplementation((id:string,page:number) => id==='a' ? oldStudent.promise :
    page===1 ? oldPage.promise : Promise.resolve({data:[{unified_opportunity_id:'b',title:'Aluno B',provider_name:'IES',match_score:50}],count:21}));
  mocks.clicks.mockReturnValue(oldClicks.promise);
  const view=render(modal('a'));
  expect(screen.getByRole('status')).toHaveTextContent('Carregando Matches');
  view.rerender(modal('b'));
  expect(await screen.findByText('Aluno B')).toBeInTheDocument();
  await act(async () => {oldStudent.resolve({data:[{title:'Aluno A antigo'}],count:1});});
  expect(screen.queryByText('Aluno A antigo')).not.toBeInTheDocument();
  tab('Clicks'); expect(screen.getByRole('status')).toHaveTextContent('Carregando Clicks');
  tab('Matches');
  fireEvent.click(screen.getByRole('button',{name:'Próxima'}));
  expect(screen.getByRole('status')).toHaveTextContent('Carregando Matches');
  fireEvent.click(screen.getByRole('button',{name:'Anterior'}));
  expect(await screen.findByText('Aluno B')).toBeInTheDocument();
  await act(async () => {
    oldClicks.resolve({data:[{id:'old-click',entity_name:'Click antigo'}],count:1});
    oldPage.resolve({data:[{title:'Página antiga'}],count:21});
  });
  expect(screen.queryByText('Click antigo')).not.toBeInTheDocument();
  expect(screen.queryByText('Página antiga')).not.toBeInTheDocument();
  view.rerender(modal('c'));
  await waitFor(() => expect(mocks.matches).toHaveBeenLastCalledWith('c',0,expect.any(Object)));
});

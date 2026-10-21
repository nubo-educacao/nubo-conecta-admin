import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import Students from '@/pages/Students';

const mocks = vi.hoisted(() => ({ details:vi.fn(), matches:vi.fn(), clicks:vi.fn(), applications:vi.fn() }));
vi.mock('@/services/studentsService', () => ({
  getStudents:async () => ({data:[{id:'student-a',full_name:'Ana Costa'}],count:1}),
  getStudentStats:async () => ({}), importNuboStudents:vi.fn(), getStudentDetails:mocks.details,
}));
vi.mock('@/services/studentActivityService', () => ({ ACTIVITY_PAGE_SIZE:20,
  getActivityMatches:mocks.matches, getActivityClicks:mocks.clicks, getActivityApplications:mocks.applications,
}));
vi.mock('@/hooks/useStudentFilters', () => ({useStudentFilters:() => ({filters:{},setFilters:vi.fn(),clearFilters:vi.fn()})}));
vi.mock('@/components/students/StudentStats', () => ({StudentStats:() => null}));
vi.mock('@/components/students/StudentFilterModal', () => ({StudentFilterModal:() => null}));
vi.mock('@/components/students/StudentExportButton', () => ({StudentExportButton:() => null}));
afterEach(cleanup);

it('moves between profile and activity for the same student, with Matches only in activity', async () => {
  mocks.details.mockResolvedValue({profile:{full_name:'Ana Costa'},preferences:null,enem_scores:[],favorites:[],matches:[],total_matches:0});
  mocks.matches.mockResolvedValue({data:[{unified_opportunity_id:'mec_1',title:'Direito',provider_name:'Universidade',match_score:85}],count:1});
  mocks.clicks.mockResolvedValue({data:[],count:0});
  mocks.applications.mockResolvedValue({data:[],count:0});
  const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});
  render(<QueryClientProvider client={client}><Students /></QueryClientProvider>);
  fireEvent.click(await screen.findByRole('button',{name:'Ver perfil'}));
  await screen.findByRole('heading',{name:'Perfil do estudante'});
  await screen.findByRole('tab',{name:'Perfil Geral'});
  expect(screen.getAllByRole('tab')).toHaveLength(2);
  expect(screen.queryByRole('tab',{name:/Match/})).not.toBeInTheDocument();
  expect(mocks.details).toHaveBeenCalledWith('student-a',0,{includeMatches:false});
  expect(mocks.matches).not.toHaveBeenCalled();
  fireEvent.click(screen.getAllByRole('button',{name:'Ver atividade'}).at(-1)!);
  await screen.findByRole('heading',{name:'Atividade do estudante'});
  expect(await screen.findByText('Direito')).toBeInTheDocument();
  expect(mocks.matches).toHaveBeenCalledWith('student-a',0,{});
  expect(screen.getAllByRole('tab')).toHaveLength(3);
  fireEvent.click(screen.getAllByRole('button',{name:'Ver perfil'}).at(-1)!);
  await screen.findByRole('heading',{name:'Perfil do estudante'});
  expect(screen.queryByRole('heading',{name:'Atividade do estudante'})).not.toBeInTheDocument();
  expect(screen.getAllByRole('tab')).toHaveLength(2);
  client.clear();
});

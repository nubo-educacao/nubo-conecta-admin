import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import * as XLSX from 'xlsx';
import { StudentExportButton } from '@/components/students/StudentExportButton';
const mocks=vi.hoisted(()=>({students:vi.fn(),stats:vi.fn(),write:vi.fn()}));
vi.mock('@/services/studentsService',()=>({getStudents:mocks.students,getStudentStats:mocks.stats}));
vi.mock('@/hooks/useAttributionFilterOptions',()=>({useAttributionFilterOptions:()=>({options:{campaigns:[],channels:[]}})}));
vi.mock('xlsx',async()=>({...await vi.importActual<typeof import('xlsx')>('xlsx'),writeFile:mocks.write}));
afterEach(cleanup);
it('preserves filtered XLSX selection and all four existing sheets with activity summaries',async()=>{
  const filters={fullName:'Ana',city:'São Paulo',campaignId:'campaign',channelId:'channel'};
  mocks.stats.mockResolvedValue({total_students:1,total_cities:1,total_states:1,average_age:20});
  mocks.students.mockResolvedValue({count:1,data:[{id:'student',full_name:'Ana',age:20,city:'São Paulo',
    total_matches:25,matches_list:'Curso A; Curso B',favorites_list:'Curso C',
    completed_applications_count:2,completed_applications_list:'Bolsa A; Bolsa B'}]});
  render(<StudentExportButton filters={filters}/>);
  fireEvent.click(screen.getByRole('button',{name:'Exportar seleção'}));
  await waitFor(()=>expect(mocks.write).toHaveBeenCalledTimes(1));
  expect(mocks.stats).toHaveBeenCalledWith(filters);
  expect(mocks.students).toHaveBeenCalledWith({page:0,pageSize:10000,filters});
  const [book,name]=mocks.write.mock.calls[0];
  expect(name).toBe('Relatorio_Estudantes_Nubo.xlsx');
  expect(book.SheetNames).toEqual(['Resumo','Perfil Geral','Matchs','Favoritos']);
  const matches=XLSX.utils.sheet_to_json<any[]>(book.Sheets.Matchs,{header:1});
  expect(matches[1]).toEqual(['Ana','student','-',25,'Curso A; Curso B']);
  const favorites=XLSX.utils.sheet_to_json<any[]>(book.Sheets.Favoritos,{header:1});
  expect(favorites[1]).toEqual(['Ana','student','-','Curso C']);
  const profile=XLSX.utils.sheet_to_json<any[]>(book.Sheets['Perfil Geral'],{header:1});
  expect(profile[1][11]).toBe('Bolsa A; Bolsa B (2)');
});


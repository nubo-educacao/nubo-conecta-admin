import { analyticsCsv } from './analyticsCsv';

it('escapes CSV separators/quotes and prevents formulas in names', () => {
  expect(analyticsCsv(['Nome', 'Mensagens'], [['=1+1', 3], ['A;"B"', 2]]))
    .toBe('\uFEFF"Nome";"Mensagens"\n"\'=1+1";"3"\n"A;""B""";"2"');
});

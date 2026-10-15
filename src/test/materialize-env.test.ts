/**
 * NUB-RD-86 — o build do admin recebe a config do Snaps, não da Vercel.
 * Contrato do arquivo resgatado: snaps-api services/materializacao.py `_linha`.
 */
import { describe, expect, it } from 'vitest';
import {
  chavesSuspeitas,
  linhasDeMascara,
  materializar,
  paraGithubEnv,
  parseStackEnv,
} from '../../scripts/ci/materialize-env';

const ARQUIVO = [
  'VITE_SUPABASE_URL=https://yfgciamhzjvarwgzosto.supabase.co',
  'SNAPS_API_KEY=chave-do-servidor',
  "COM_ESPACO='valor com espaco e $VAR # nao e comentario'",
  '',
].join('\n');

describe('parseStackEnv', () => {
  it('lê valor cru e entre aspas simples sem alterar nada', () => {
    expect(parseStackEnv(ARQUIVO)).toEqual({
      VITE_SUPABASE_URL: 'https://yfgciamhzjvarwgzosto.supabase.co',
      SNAPS_API_KEY: 'chave-do-servidor',
      COM_ESPACO: 'valor com espaco e $VAR # nao e comentario',
    });
  });

  it('recusa linha fora do contrato citando só o número da linha', () => {
    expect(() => parseStackEnv('SEM_IGUAL_sentinela')).toThrow(/linha 1/);
    expect(() => parseStackEnv('SEM_IGUAL_sentinela')).not.toThrow(/sentinela/);
  });

  it('recusa arquivo vazio', () => {
    expect(() => parseStackEnv('\n')).toThrow(/vazio/);
  });
});

describe('chavesSuspeitas', () => {
  it('aponta VITE_* com nome de segredo (iria para o bundle)', () => {
    expect(chavesSuspeitas([
      'VITE_SUPABASE_PUBLISHABLE_KEY', 'VITE_SNAPS_API_KEY', 'VITE_X_SECRET',
      'VITE_GH_TOKEN', 'VITE_DB_PASSWORD', 'VITE_SERVICE_ROLE', 'SNAPS_API_KEY',
    ])).toEqual(['VITE_SNAPS_API_KEY', 'VITE_X_SECRET', 'VITE_GH_TOKEN', 'VITE_DB_PASSWORD', 'VITE_SERVICE_ROLE']);
  });

  it('chave de servidor (sem VITE_) é permitida: não vai para o bundle', () => {
    expect(chavesSuspeitas(['SNAPS_API_KEY', 'SNAPS_API_URL'])).toEqual([]);
  });
});

describe('máscaras e $GITHUB_ENV', () => {
  it('mascara todo valor não vazio', () => {
    expect(linhasDeMascara({ A: 'x1', B: '' })).toEqual(['::add-mask::x1']);
  });

  it('heredoc com delimitador preserva $, # e espaço; recusa valor com o delimitador', () => {
    expect(paraGithubEnv({ B: 'com $VAR # e espaço' }, 'D_x')).toBe('B<<D_x\ncom $VAR # e espaço\nD_x\n');
    expect(() => paraGithubEnv({ A: 'tem D_x' }, 'D_x')).toThrow(/A/);
  });
});

describe('materializar', () => {
  it('recusa o build se a chave do Snaps voltar a ser pública, citando só o nome', () => {
    const arquivo = 'VITE_SNAPS_API_KEY=valor-sentinela\nVITE_SUPABASE_URL=u\n';
    expect(() => materializar(arquivo)).toThrow(/VITE_SNAPS_API_KEY/);
    expect(() => materializar(arquivo)).not.toThrow(/valor-sentinela/);
  });

  it('devolve nomes, máscaras e o bloco de $GITHUB_ENV', () => {
    const r = materializar(ARQUIVO, 'D_y');
    expect(r.chaves).toEqual(['COM_ESPACO', 'SNAPS_API_KEY', 'VITE_SUPABASE_URL']);
    expect(r.mascaras).toHaveLength(3);
    expect(r.githubEnv).toContain('SNAPS_API_KEY<<D_y\nchave-do-servidor\nD_y\n');
  });
});

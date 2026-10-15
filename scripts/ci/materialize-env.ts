/**
 * NUB-RD-86 — transforma o arquivo resgatado do Snaps (materialização OIDC,
 * ADR-NUBO-DEPLOY-01) em variáveis de ambiente do job, sem imprimir valor.
 * Mesmo contrato do nubo-conecta-app (scripts/ci/materialize-env.mjs), com o
 * prefixo público do Vite.
 *
 * Uso: node scripts/ci/materialize-env.ts <arquivo-resgatado>   (Node 24, .ts nativo)
 *   stdout: `::add-mask::<valor>` por valor, depois só os NOMES das chaves.
 *   efeito: acrescenta as variáveis a $GITHUB_ENV.
 *
 * $GITHUB_ENV e não .env: o Vite expande `$VAR` em arquivos .env (dotenv-expand),
 * mas não em variável que já está no ambiente do processo.
 */
import { randomBytes } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const CHAVE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const NOME_DE_SEGREDO = /(SECRET|SERVICE_ROLE|PRIVATE|TOKEN|PASSWORD|_API_KEY)/;
/** Tudo com este prefixo vai para o bundle público do Vite. */
export const PREFIXO_PUBLICO = 'VITE_';

/** Lê o formato do snaps-api (`_linha`): valor cru ou entre aspas simples. */
export function parseStackEnv(conteudo: string): Record<string, string> {
  const valores: Record<string, string> = {};
  conteudo.split(/\r?\n/).forEach((linha, i) => {
    if (linha.trim() === '') return;
    const igual = linha.indexOf('=');
    const chave = igual > 0 ? linha.slice(0, igual) : '';
    if (!CHAVE.test(chave)) throw new Error(`arquivo resgatado fora do contrato na linha ${i + 1}`);
    let valor = linha.slice(igual + 1);
    if (valor.length >= 2 && valor.startsWith("'") && valor.endsWith("'")) valor = valor.slice(1, -1);
    valores[chave] = valor;
  });
  if (Object.keys(valores).length === 0) {
    throw new Error('arquivo resgatado vazio: o environment do Snaps não tem chaves');
  }
  return valores;
}

/** Chave pública com nome de segredo iria para o bundle: é erro. */
export function chavesSuspeitas(chaves: string[]): string[] {
  return chaves.filter((c) => c.startsWith(PREFIXO_PUBLICO) && NOME_DE_SEGREDO.test(c));
}

export function linhasDeMascara(valores: Record<string, string>): string[] {
  return Object.values(valores).filter((v) => v !== '').map((v) => `::add-mask::${v}`);
}

export function paraGithubEnv(valores: Record<string, string>, delimitador: string): string {
  return Object.entries(valores)
    .map(([chave, valor]) => {
      if (valor.includes(delimitador)) throw new Error(`valor de ${chave} contém o delimitador do heredoc`);
      return `${chave}<<${delimitador}\n${valor}\n${delimitador}\n`;
    })
    .join('');
}

export function materializar(conteudo: string, delimitador = `SNAPS_${randomBytes(16).toString('hex')}`) {
  const valores = parseStackEnv(conteudo);
  const chaves = Object.keys(valores).sort();
  const suspeitas = chavesSuspeitas(chaves);
  if (suspeitas.length > 0) {
    throw new Error(`chave(s) públicas com nome de segredo, que iriam para o bundle: ${suspeitas.join(', ')}`);
  }
  return { chaves, mascaras: linhasDeMascara(valores), githubEnv: paraGithubEnv(valores, delimitador) };
}

function principal(): void {
  const [arquivo] = process.argv.slice(2);
  const destino = process.env.GITHUB_ENV;
  if (!arquivo || !destino) {
    console.error('uso: materialize-env.ts <arquivo>  (com GITHUB_ENV definido)');
    process.exit(2);
  }
  try {
    const r = materializar(readFileSync(arquivo, 'utf8'));
    for (const m of r.mascaras) console.log(m);
    appendFileSync(destino, r.githubEnv, { mode: 0o600 });
    console.log(`config do Snaps materializada: ${r.chaves.length} chave(s): ${r.chaves.join(', ')}`);
  } catch (erro) {
    console.error(`::error::${(erro as Error).message}`);
    process.exit(1);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) principal();

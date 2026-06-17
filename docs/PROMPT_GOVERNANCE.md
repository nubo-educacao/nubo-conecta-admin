# Governança dos Prompts de Agentes (Cloudinha)

## Regra de ouro
**O prompt dos agentes muda SOMENTE pelo Backoffice** (Configuração e Prompts dos Agentes →
`SystemInstructionsEditor`), que escreve em `agent_prompts`. O banco é a **fonte da verdade**
e é lido em runtime pelo agente.

Nenhum outro caminho deve escrever em `agent_prompts.system_instruction`:

- 🚫 **SEM MIGRATIONS**: É ESTRITAMENTE PROIBIDO criar migrations SQL (ex: `supabase/migrations/xxxxx_update_prompt.sql`) para atualizar o texto do prompt. Isso quebra o versionamento dinâmico e gera conflitos com o Backoffice.
- 🚫 Sem atualizações diretas no banco em Produção usando o Supabase Studio
- 🚫 Sem scripts `.mjs` no repositório do agente. O antigo `update-system-prompt.mjs` foi permanentemente DELETADO.
- ❌ **Migrations de prompt** (ex.: `..._cloudinha_react_prompt_v*.sql`): legado. Não criar
  novas migrations que dão `UPDATE` em `system_instruction`.

Por quê: ter múltiplos escritores na mesma linha causou **drift** (edição no backoffice sendo
sobrescrita por um run de script/migration). Um único dono elimina isso.

## Versionamento / rollback
Toda alteração em `agent_prompts` grava a versão **anterior** em `agent_prompt_versions`
automaticamente, via trigger `trg_snapshot_agent_prompt_version`
(migration `20260614160000_agent_prompt_versions.sql`). Independe de qual caminho fez o update.

Service helpers: `getAgentPromptVersions(agentKey)` e `restoreAgentPromptVersion(promptId, version)`
em `src/services/agentConfigService.ts`. (UI de histórico/restore no `SystemInstructionsEditor`
é o próximo passo de frontend.)

## Schema/colunas no prompt
Não hardcodar listas de colunas no prompt. As tabelas/colunas válidas vêm do bloco
`{{SCHEMA_CONTEXT}}`, auto-descoberto em runtime. Hardcodar gera drift (foi a causa do bug RC2).

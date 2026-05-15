-- Crie a Sprint 11
WITH new_sprint AS (
  INSERT INTO sprints (project_id, name, tag, status)
  VALUES ('d5142c4c-efaf-4af8-9399-0cd9864963f7', 'Sprint 11.0 (Macro Plan)', 'sprint-11.0', 'planned')
  RETURNING id
)
-- Insira os cards associados à Sprint 11
INSERT INTO cards (board_id, sprint_id, title, description, card_type, status, priority)
SELECT 
  '62239aba-2210-4c99-a158-240af7bd6f2c',
  id,
  title,
  description,
  card_type,
  'todo',
  priority
FROM new_sprint, (
  VALUES
  (
    'Card 9.4.1 — Bug: RPC submit_application_v1 → 404',
    'A RPC submit_application_v1 retorna 404 ao enviar candidatura no último step.\n\nInvestigar:\n1. Verificar se a função existe no banco: SELECT proname FROM pg_proc WHERE proname ILIKE ''%application%'';\n2. Alinhar nome chamado no frontend com o existente no banco\n3. Se não existir: criar RPC submit_application_v1(p_partner_opportunity_id, p_profile_id, p_answers)\n\nCritérios de Aceite:\n- Candidatura é criada com sucesso\n- Usuário é redirecionado para Minhas Candidaturas após envio\n- Registro aparece na tela de Candidaturas do app e no admin',
    'bug',
    'High'
  ),
  (
    'Card 9.4.2 — Bug: Seletor de Perfil no Step 1',
    'O seletor de perfil (principal/dependente) na tela de candidatura (/partner-forms/[id]) está vazando para os steps seguintes.\n\nCritérios de Aceite:\n- O seletor de perfil é exibido somente no Step 1 (Identificação)\n- Ao avançar para o Step 2 (Revisão, Elegibilidade, etc.), o seletor desaparece\n- O profileId selecionado no Step 1 é mantido no estado do formulário e passado corretamente na submissão final',
    'bug',
    'High'
  ),
  (
    'Card 9.4.3 — Bug: Pré-preenchimento Adaptativo por Perfil',
    'Ao trocar de perfil no Step 1, os campos de identificação (nome, CPF, telefone) não estão refletindo corretamente os dados do novo perfil selecionado.\n\nCritérios de Aceite:\n- Ao selecionar o perfil principal, os dados do usuário principal populam os inputs\n- Ao selecionar um dependente, os inputs são limpos ou preenchidos com os dados do dependente (se existirem)\n- Evitar vazamento de estado (estado de um formulário preenchido pela metade não deve contaminar o próximo perfil selecionado)',
    'bug',
    'High'
  ),
  (
    'Card 9.1.3 — Correção do ETL ProUni (type mismatch)',
    'A RPC etl_prouni_vacancies falha com erro operator does not exist: bigint = text por incompatibilidade de tipo na coluna CO_CURSO entre rawprounivacancies2025 e rawprouniocuppied2025.\n\nCritérios de Aceite:\n- etl_prouni_vacancies executa sem erros\n- opportunities_prouni_vacancies é populada com dados de bolsas ofertadas e ocupadas\n- Vagas do ProUni aparecem na tela de detalhes da oportunidade',
    'bug',
    'High'
  ),
  (
    'Card 9.2.1 — DB Schema: Tabela programs',
    'Criar a tabela programs para gerenciar SiSU e ProUni. \n\nSchema proposto:\nid UUID PK, type TEXT, cycle_year INTEGER, cycle_semester TEXT, title TEXT, description TEXT, status TEXT DEFAULT ''inactive'', redirect_url TEXT, starts_at TIMESTAMPTZ, ends_at TIMESTAMPTZ.\n\nCritérios de Aceite:\n- RLS configurada (leitura pública, escrita apenas service_role)\n- Seeds iniciais para SISU 2026 e ProUni 2025.1 com os textos atuais',
    'feature',
    'Medium'
  ),
  (
    'Card 9.2.2 — Admin UI: CRUD de Programs',
    'Tela no admin para gerenciar Programs:\n- Listagem por tipo (SiSU / ProUni) e ciclo\n- Formulário de criação/edição (título, descrição, datas, link, status)\n- Toggle de status (ativo/inativo/encerrado)\n- Preview do texto Sobre o programa',
    'feature',
    'Medium'
  ),
  (
    'Card 9.3.1 — Status inactive para Partner Opportunities',
    'Adicionar suporte ao status inactive em partner_opportunities:\n- Admin pode marcar uma oportunidade como inativa\n- Oportunidades inativas não aparecem no catálogo do app nem em buscas\n- v_unified_opportunities filtra status != ''inactive''\n- Na tela de detalhes (via link direto), exibe Oportunidade não disponível',
    'feature',
    'High'
  ),
  (
    'Card 9.1.1 — ETL Admin Interface',
    'Criar uma tela no nubo-conecta-admin para gerenciar o ciclo de importação MEC:\n- Upload de arquivos CSV brutos (SISU e ProUni) para o storage do Supabase\n- Seleção de ano/semestre do ciclo a importar\n- Botões de execução das RPCs ETL\n- Log de execução com status de cada etapa\n\nCritérios de Aceite:\n- Admin consegue importar um ciclo novo sem acesso ao SQL Editor\n- Interface mostra feedback de sucesso/erro por etapa\n- Importação é idempotente',
    'feature',
    'High'
  ),
  (
    'Card 9.2.3 — Action Center: Alertas por Datas do Program',
    'Integrar Programs ao Action Center do admin com alertas baseados em datas:\n- Alerta D-3 antes de starts_at: Inscrições abrem em 3 dias. Ativar?\n- Alerta em ends_at: Inscrições encerraram. Fechar programa?\n- Admin clica em Confirmar -> status muda automaticamente\n\nCritérios de Aceite:\n- Alertas aparecem no Action Center nos momentos corretos\n- Ação do admin atualiza programs.status',
    'feature',
    'Medium'
  ),
  (
    'Card 9.2.4 — App: Botão Candidatar Dinâmico por Program Status',
    'A tela de detalhes de oportunidade MEC deve consultar o program para decidir o botão Candidatar-se:\n- active: botão habilitado -> abre redirect_url\n- inactive: botão desabilitado (Inscrições em breve)\n- closed: botão substituído por badge (Inscrições encerradas)',
    'feature',
    'Medium'
  ),
  (
    'Card 9.3.2 — Critérios de Elegibilidade e Priorização',
    'Evoluir o sistema de critérios de oportunidades parceiras.\n\nEstrutura de Critério Composto (AND/OR, field, op, value).\n2 Seções: Elegibilidade (obrigatórios) e Priorização (preferenciais).\n\nAdmin UI: builder visual de critérios compostos.\nApp UI: 2 seções distintas na tela de detalhes (Você é elegível? e O que priorizam?)',
    'feature',
    'Medium'
  ),
  (
    'Card 9.1.2 — Pipeline Year-Agnostic',
    'Refatorar as RPCs ETL e as queries da v_unified_opportunities para serem parametrizadas por year e semester ao invés de hardcoded em 2025.\n\nCritérios de Aceite:\n- View retorna dados corretos para qualquer ciclo importado\n- Nenhuma coluna com ano hardcoded nas queries do app\n- Colunas qt_inscricao, vagas_ociosas são computadas da tabela mais recente',
    'feature',
    'High'
  ),
  (
    'Card 9.2.5 — App: Migrar Textos Hardcoded para Programs',
    'Remover os textos estáticos de Sobre o SiSU e Sobre o ProUni do SisuProuniCard.tsx e buscá-los da tabela programs.\n\nCritérios de Aceite:\n- Descrição dinâmica\n- Título do card dinâmico\n- Suporte a rich text (markdown simples)',
    'feature',
    'Low'
  ),
  (
    'Card 9.3.3 — Redirect + new-application Flow',
    'Para oportunidades com external_redirect.enabled = true, alterar o comportamento:\nCandidatar -> /partner-forms/[id] -> pré-qualificação -> link externo.\n\nEtapas: 1. Identificação, 2. Elegibilidade, 3. Revisão + Ir para inscrição oficial.\n\nCritérios de Aceite:\n- student_application criada com status = ''redirected''\n- Usuário vê resultado da pré-qualificação',
    'feature',
    'Medium'
  ),
  (
    'Card 9.3.4 — Important Dates na Tela de Detalhes',
    'Adicionar seção Datas Importantes na tela de detalhes da oportunidade:\n- Para MEC: busca em important_dates\n- Para Partner: datas configuradas na própria oportunidade\n- Componente visual com timeline horizontal ou lista de cards',
    'feature',
    'Low'
  )
) AS v(title, description, card_type, priority);

import { Badge } from '@/components/ui/badge';

interface SystemIntent {
  command: string;
  description: string;
  isActive: boolean;
  trigger: string;
}

const SYSTEM_INTENTS: SystemIntent[] = [
  {
    command: 'get_starters',
    description: 'Busca os Conversation Starters da rota atual ao abrir o drawer.',
    isActive: true,
    trigger: 'Abertura do Drawer Cloudinha',
  },
  {
    command: 'proactive_open',
    description: 'Abre o drawer automaticamente após 5 segundos de inatividade.',
    isActive: true,
    trigger: '5s após carga da página (frontend)',
  },
  {
    command: 'clear_session',
    description: 'Limpa o histórico da sessão de chat atual.',
    isActive: true,
    trigger: 'Manual (botão de limpar)',
  },
  {
    command: 'ping',
    description: 'Health check do pipeline da Cloudinha.',
    isActive: true,
    trigger: 'Diagnóstico',
  },
];

export default function SystemIntentsViewer() {
  return (
    <div className="space-y-4">
      <div>
        <h3 className="text-lg font-semibold">System Intents</h3>
        <p className="text-sm text-muted-foreground">
          Comandos internos processados sem passar pelo pipeline LLM completo.
          Gestão automática — configuração avançada disponível em versão futura.
        </p>
      </div>
      <div className="space-y-3">
        {SYSTEM_INTENTS.map((intent) => (
          <div
            key={intent.command}
            className="flex items-start gap-4 rounded-lg border bg-card p-4"
          >
            <Badge variant={intent.isActive ? 'default' : 'secondary'} className="mt-0.5">
              {intent.isActive ? 'Ativo' : 'Inativo'}
            </Badge>
            <div className="flex-1 min-w-0">
              <p className="font-mono text-sm font-semibold">{intent.command}</p>
              <p className="text-sm text-muted-foreground mt-0.5">{intent.description}</p>
              <p className="text-xs text-muted-foreground mt-1">
                <span className="font-medium">Trigger:</span> {intent.trigger}
              </p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

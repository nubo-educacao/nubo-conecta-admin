import { useState, useEffect, useRef } from "react";
import { MessageSquare, ChevronLeft, ChevronRight, User, Cloud, Loader2, MapPin, GraduationCap, Calendar, Hash, Filter, GitBranch, Target, Search, ChevronUp, CalendarDays, Phone, Copy, Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { cn } from "@/lib/utils";
import { format, formatDistanceToNow, subDays, startOfDay, endOfDay } from "date-fns";
import { ptBR } from "date-fns/locale";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Calendar as CalendarComponent } from "@/components/ui/calendar";

interface ChatMessage {
  id: string;
  content: string;
  sender: string;
  workflow: string | null;
  created_at: string;
}

interface UserSummary {
  user_id: string;
  user_name: string;
  city: string | null;
  age: number | null;
  funnel_stage: string | null;
  last_activity: string | null;
  total_messages: number;
  workflow: string | null;
}

interface UserConversation {
  user_id: string;
  user_name: string;
  phone: string | null;
  city: string | null;
  location_preference: string | null;
  age: number | null;
  education: string | null;
  active_workflow: string | null;
  first_contact: string | null;
  last_activity: string | null;
  total_messages: number;
  workflow: string | null;
  funnel_stage: string | null;
  has_more_messages: boolean;
  messages: ChatMessage[];
}

const workflowLabels: Record<string, string> = {
  'match_workflow': 'Match',
  'sisu_workflow': 'SISU',
  'prouni_workflow': 'ProUni',
  'fies_workflow': 'FIES',
  'onboarding_workflow': 'Onboarding',
};

const educationLabels: Record<string, string> = {
  'ensino_medio': 'Ensino Médio',
  'ensino_medio_completo': 'Ensino Médio Completo',
  'cursando_superior': 'Cursando Superior',
  'superior_completo': 'Superior Completo',
};

const funnelStages = [
  { value: 'all', label: 'Todas as etapas' },
  { value: 'Cadastrados', label: 'Cadastrados' },
  { value: 'Onboarding Completo', label: 'Onboarding Completo' },
  { value: 'Preferências Definidas', label: 'Preferências Definidas' },
  { value: 'Match Iniciado', label: 'Match Iniciado' },
  { value: 'Match Realizado', label: 'Match Realizado' },
  { value: 'Salvaram Favoritos', label: 'Salvaram Favoritos' },
  { value: 'Fluxo Específico', label: 'Fluxo Específico' },
];

const funnelStageColors: Record<string, string> = {
  'Cadastrados': 'bg-chart-1/10 text-chart-1 border-chart-1/30',
  'Onboarding Completo': 'bg-chart-2/10 text-chart-2 border-chart-2/30',
  'Preferências Definidas': 'bg-chart-3/10 text-chart-3 border-chart-3/30',
  'Match Iniciado': 'bg-chart-4/10 text-chart-4 border-chart-4/30',
  'Match Realizado': 'bg-emerald-500/10 text-emerald-600 border-emerald-500/30',
  'Salvaram Favoritos': 'bg-chart-5/10 text-chart-5 border-chart-5/30',
  'Fluxo Específico': 'bg-success/10 text-success border-success/30',
};

interface ChatExamplesPanelProps {
  fullPage?: boolean;
}

const datePresets = [
  { value: 'today', label: 'Hoje', getRange: () => ({ from: startOfDay(new Date()), to: endOfDay(new Date()) }) },
  { value: 'yesterday', label: 'Ontem', getRange: () => ({ from: startOfDay(subDays(new Date(), 1)), to: endOfDay(subDays(new Date(), 1)) }) },
  { value: 'last7days', label: 'Últimos 7 dias', getRange: () => ({ from: startOfDay(subDays(new Date(), 7)), to: endOfDay(new Date()) }) },
  { value: 'last30days', label: 'Últimos 30 dias', getRange: () => ({ from: startOfDay(subDays(new Date(), 30)), to: endOfDay(new Date()) }) },
  { value: 'custom', label: 'Personalizado', getRange: () => null },
];

// Format relative time for last activity
const formatRelativeTime = (dateString: string | null) => {
  if (!dateString) return 'N/A';
  const date = new Date(dateString);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'agora';
  if (diffMins < 60) return `há ${diffMins} min`;
  if (diffHours < 24) return `há ${diffHours}h`;
  if (diffDays < 7) return `há ${diffDays} dias`;
  return format(date, "dd/MM", { locale: ptBR });
};

export function ChatExamplesPanel({ fullPage = false }: ChatExamplesPanelProps) {
  // Phase 1: User list (fast load)
  const [userList, setUserList] = useState<UserSummary[]>([]);
  const [loadingList, setLoadingList] = useState(true);
  const [visibleCount, setVisibleCount] = useState(30);

  // Phase 2: Active conversation (on-demand load)
  const [activeConversation, setActiveConversation] = useState<UserConversation | null>(null);
  const [loadingConversation, setLoadingConversation] = useState(false);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);

  const [error, setError] = useState<string | null>(null);
  const [funnelFilter, setFunnelFilter] = useState('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [loadingMore, setLoadingMore] = useState(false);
  const [copiedPhone, setCopiedPhone] = useState<string | null>(null);
  const chatContainerRef = useRef<HTMLDivElement>(null);

  // Date filter states
  const [datePreset, setDatePreset] = useState('last30days');
  const [dateFrom, setDateFrom] = useState<Date | undefined>(subDays(new Date(), 30));
  const [dateTo, setDateTo] = useState<Date | undefined>(new Date());
  const [isDatePopoverOpen, setIsDatePopoverOpen] = useState(false);

  // Phase 1: Fetch user list (fast)
  const fetchUserList = async () => {
    try {
      setLoadingList(true);
      setError(null);
      console.log('Fetching user list (fast mode):', { dateFrom, dateTo });

      const requestBody: {
        mode: 'list';
        date_from?: string;
        date_to?: string
      } = { mode: 'list' };

      if (dateFrom) {
        requestBody.date_from = startOfDay(dateFrom).toISOString();
      }
      if (dateTo) {
        requestBody.date_to = endOfDay(dateTo).toISOString();
      }

      let allUsers: UserSummary[] = [];
      let page = 0;
      const pageSize = 1000;
      let hasMore = true;

      while (hasMore) {
        // @ts-ignore - RPC not yet typed
        const { data, error: fetchError } = await supabase
          .rpc('get_chat_analytics_summary', {
            p_date_from: requestBody.date_from || startOfDay(subDays(new Date(), 30)).toISOString(),
            p_date_to: requestBody.date_to || endOfDay(new Date()).toISOString()
          })
          .range(page * pageSize, (page + 1) * pageSize - 1);

        if (fetchError) {
          console.error('Error from RPC get_chat_analytics_summary:', fetchError);
          throw fetchError;
        }

        const pageData = data as unknown as UserSummary[];

        if (pageData && Array.isArray(pageData)) {
          allUsers = [...allUsers, ...pageData];
          if (pageData.length < pageSize) {
            hasMore = false;
          } else {
            page++;
          }
        } else {
          hasMore = false;
        }
      }

      if (allUsers.length > 0) {
        console.log('Loaded', allUsers.length, 'users (RPC batch mode)');
        setUserList(allUsers);
        setVisibleCount(30);

        // Auto-select first user if none selected
        if (allUsers.length > 0 && !selectedUserId) {
          loadConversation(allUsers[0].user_id);
        }
      } else {
        console.warn('Unexpected data format from RPC:', data);
        setUserList([]);
      }
    } catch (e) {
      console.error('Error fetching user list:', e);
      setError('Erro ao carregar conversas. Clique para tentar novamente.');
    } finally {
      setLoadingList(false);
    }
  };

  // Phase 2: Load conversation details on-demand
  const loadConversation = async (userId: string) => {
    try {
      setLoadingConversation(true);
      setSelectedUserId(userId);
      console.log('Loading conversation for user:', userId);

      const { data, error: fetchError } = await supabase.functions.invoke('analytics-chats', {
        body: {
          mode: 'conversation',
          user_id: userId
        }
      });

      if (fetchError) {
        console.error('Error loading conversation:', fetchError);
        return;
      }

      if (data) {
        setActiveConversation(data);

        // Scroll to bottom of messages
        setTimeout(() => {
          if (chatContainerRef.current) {
            chatContainerRef.current.scrollTop = chatContainerRef.current.scrollHeight;
          }
        }, 100);
      }
    } catch (e) {
      console.error('Error loading conversation:', e);
    } finally {
      setLoadingConversation(false);
    }
  };

  // Handle date preset change
  const handleDatePresetChange = (preset: string) => {
    setDatePreset(preset);
    const presetConfig = datePresets.find(p => p.value === preset);
    if (presetConfig && preset !== 'custom') {
      const range = presetConfig.getRange();
      if (range) {
        setDateFrom(range.from);
        setDateTo(range.to);
      }
    }
  };

  useEffect(() => {
    setSelectedUserId(null);
    setActiveConversation(null);
    setVisibleCount(30);
    fetchUserList();
  }, [dateFrom, dateTo]);

  // Filter users by funnel stage and search query
  const filteredUsers = userList.filter(u => {
    const matchesFunnel = funnelFilter === 'all' || u.funnel_stage === funnelFilter;
    const matchesSearch = searchQuery === '' ||
      u.user_name.toLowerCase().includes(searchQuery.toLowerCase());
    return matchesFunnel && matchesSearch;
  });

  const visibleUsers = filteredUsers.slice(0, visibleCount);

  // Load more messages for current conversation
  const loadMoreMessages = async () => {
    if (!activeConversation || loadingMore) return;

    const currentMessagesCount = activeConversation.messages.length;

    try {
      setLoadingMore(true);

      // Save scroll height before loading
      const container = chatContainerRef.current;
      const scrollHeightBefore = container?.scrollHeight || 0;

      const { data, error: fetchError } = await supabase.functions.invoke('analytics-chats', {
        body: {
          mode: 'conversation',
          user_id: activeConversation.user_id,
          offset: currentMessagesCount,
          messages_limit: 20
        }
      });

      if (fetchError) {
        console.error('Error loading more messages:', fetchError);
        return;
      }

      if (data && data.messages && Array.isArray(data.messages)) {
        // Update the conversation with new messages prepended
        setActiveConversation(prev => {
          if (!prev) return prev;
          return {
            ...prev,
            messages: [...data.messages, ...prev.messages],
            has_more_messages: data.has_more_messages
          };
        });

        // After state update, maintain scroll position
        setTimeout(() => {
          if (container) {
            const scrollHeightAfter = container.scrollHeight;
            container.scrollTop = scrollHeightAfter - scrollHeightBefore;
          }
        }, 0);
      }
    } catch (e) {
      console.error('Error loading more messages:', e);
    } finally {
      setLoadingMore(false);
    }
  };

  if (loadingList) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full text-muted-foreground">
        <MessageSquare className="h-12 w-12 mb-4 opacity-50" />
        <p className="mb-4">{error}</p>
        <Button variant="outline" size="sm" onClick={fetchUserList}>
          Tentar novamente
        </Button>
      </div>
    );
  }

  if (userList.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-full text-muted-foreground">
        <MessageSquare className="h-12 w-12 mb-4 opacity-50" />
        <p>Nenhuma conversa encontrada</p>
      </div>
    );
  }

  return (
    <div className="flex h-full gap-4">
      {/* Left Sidebar - User List */}
      <div className="w-72 flex-shrink-0 flex flex-col border-r border-border pr-4">
        {/* Search */}
        <div className="mb-3 flex-shrink-0">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
            <Input
              placeholder="Buscar por nome..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="pl-9"
            />
          </div>
        </div>

        {/* Date Filter */}
        <div className="mb-3 flex-shrink-0">
          <div className="flex items-center gap-2 mb-2">
            <CalendarDays className="h-4 w-4 text-muted-foreground" />
            <span className="text-sm font-medium">Período</span>
          </div>
          <Select value={datePreset} onValueChange={handleDatePresetChange}>
            <SelectTrigger className="w-full mb-2">
              <SelectValue placeholder="Selecione o período" />
            </SelectTrigger>
            <SelectContent>
              {datePresets.map((preset) => (
                <SelectItem key={preset.value} value={preset.value}>
                  {preset.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>

          {datePreset === 'custom' && (
            <div className="space-y-2">
              <Popover open={isDatePopoverOpen} onOpenChange={setIsDatePopoverOpen}>
                <PopoverTrigger asChild>
                  <Button
                    variant="outline"
                    size="sm"
                    className="w-full justify-start text-left font-normal"
                  >
                    <Calendar className="mr-2 h-4 w-4" />
                    {dateFrom && dateTo ? (
                      <span className="truncate">
                        {format(dateFrom, "dd/MM", { locale: ptBR })} - {format(dateTo, "dd/MM", { locale: ptBR })}
                      </span>
                    ) : (
                      <span>Selecionar datas</span>
                    )}
                  </Button>
                </PopoverTrigger>
                <PopoverContent className="w-auto p-0" align="start">
                  <CalendarComponent
                    mode="range"
                    selected={{ from: dateFrom, to: dateTo }}
                    onSelect={(range) => {
                      setDateFrom(range?.from);
                      setDateTo(range?.to);
                      if (range?.from && range?.to) {
                        setIsDatePopoverOpen(false);
                      }
                    }}
                    numberOfMonths={1}
                    locale={ptBR}
                    disabled={(date) => date > new Date()}
                  />
                </PopoverContent>
              </Popover>
            </div>
          )}

          {dateFrom && dateTo && datePreset !== 'custom' && (
            <p className="text-xs text-muted-foreground mt-1">
              {format(dateFrom, "dd/MM/yyyy", { locale: ptBR })} - {format(dateTo, "dd/MM/yyyy", { locale: ptBR })}
            </p>
          )}
        </div>

        {/* Funnel Filter */}
        <div className="mb-3 flex-shrink-0">
          <div className="flex items-center gap-2 mb-2">
            <Filter className="h-4 w-4 text-muted-foreground" />
            <span className="text-sm font-medium">Filtrar por etapa</span>
          </div>
          <Select value={funnelFilter} onValueChange={setFunnelFilter}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder="Filtrar por etapa" />
            </SelectTrigger>
            <SelectContent>
              {funnelStages.map((stage) => (
                <SelectItem key={stage.value} value={stage.value}>
                  {stage.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {/* User Count */}
        <div className="mb-2 flex-shrink-0">
          <span className="text-sm text-muted-foreground">
            Mostrando {visibleUsers.length} de {filteredUsers.length} conversas
          </span>
        </div>

        {/* Scrollable User List */}
        <ScrollArea className="flex-1">
          <div className="space-y-1 pr-2 pb-4">
            {visibleUsers.map((user) => (
              <div
                key={user.user_id}
                onClick={() => loadConversation(user.user_id)}
                className={cn(
                  "p-2 rounded-lg cursor-pointer transition-colors",
                  "hover:bg-muted/80",
                  selectedUserId === user.user_id
                    ? "bg-primary/10 border border-primary/30"
                    : "bg-muted/30 border border-transparent"
                )}
              >
                <div className="flex items-center justify-between mb-1">
                  <span className="font-medium text-sm truncate flex-1">
                    {user.user_name}
                  </span>
                  <span className="text-xs text-muted-foreground ml-2 flex-shrink-0">
                    {formatRelativeTime(user.last_activity)}
                  </span>
                </div>
                <div className="flex items-center gap-2">
                  <Badge
                    variant="outline"
                    className={cn(
                      "text-[10px] px-1.5 py-0",
                      funnelStageColors[user.funnel_stage || ''] || "bg-muted"
                    )}
                  >
                    {user.funnel_stage}
                  </Badge>
                  <span className="text-xs text-muted-foreground">
                    {user.total_messages} msgs
                  </span>
                </div>
              </div>
            ))}

            {visibleUsers.length < filteredUsers.length && (
              <Button
                variant="ghost"
                size="sm"
                className="w-full text-xs text-muted-foreground"
                onClick={() => setVisibleCount(prev => prev + 50)}
              >
                Carregar mais ({filteredUsers.length - visibleUsers.length})
              </Button>
            )}
          </div>
        </ScrollArea>
      </div>

      {/* Main Area */}
      <div className="flex-1 flex gap-4 min-w-0">
        {/* Chat Messages */}
        <div className="flex-1 flex flex-col min-w-0">
          {/* Chat Header */}
          <div className="flex items-center gap-2 mb-3 pb-3 border-b border-border flex-shrink-0">
            <div className="h-8 w-8 rounded-full bg-primary/10 flex items-center justify-center">
              <Cloud className="h-4 w-4 text-primary" />
            </div>
            <div className="min-w-0 flex-1">
              <h3 className="font-semibold text-sm">Conversa com Cloudinha</h3>
              <p className="text-xs text-muted-foreground truncate">
                {activeConversation?.user_name || 'Selecione uma conversa'}
                {activeConversation?.city && ` • ${activeConversation.city}`}
              </p>
            </div>
            {loadingConversation && (
              <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
            )}
          </div>

          {/* Chat Messages */}
          {!activeConversation && !loadingConversation && (
            <div className="flex-1 flex items-center justify-center text-muted-foreground">
              <div className="text-center">
                <MessageSquare className="h-12 w-12 mx-auto mb-2 opacity-50" />
                <p>Selecione uma conversa na lista</p>
              </div>
            </div>
          )}

          {loadingConversation && !activeConversation && (
            <div className="flex-1 flex items-center justify-center">
              <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
            </div>
          )}

          {activeConversation && (
            <div
              ref={chatContainerRef}
              className="flex-1 overflow-y-auto rounded-lg border border-border bg-card/50 p-4"
            >
              <div className="space-y-4">
                {/* Load More Button */}
                {activeConversation.has_more_messages && (
                  <div className="flex flex-col items-center gap-2 pb-4 border-b border-border/50">
                    <span className="text-xs text-muted-foreground">
                      Mostrando {activeConversation.messages.length} de {activeConversation.total_messages} mensagens
                    </span>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={loadMoreMessages}
                      disabled={loadingMore}
                      className="gap-2"
                    >
                      {loadingMore ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <ChevronUp className="h-4 w-4" />
                      )}
                      {loadingMore ? 'Carregando...' : 'Carregar conversa anterior'}
                    </Button>
                  </div>
                )}

                {activeConversation.messages.map((message) => (
                  <div
                    key={message.id}
                    className={cn(
                      "flex gap-3",
                      message.sender === 'user' ? "justify-start" : "justify-end"
                    )}
                  >
                    {message.sender === 'user' && (
                      <div className="flex-shrink-0 w-8 h-8 rounded-full bg-muted flex items-center justify-center">
                        <User className="h-4 w-4 text-muted-foreground" />
                      </div>
                    )}

                    <div
                      className={cn(
                        "max-w-[75%] rounded-2xl px-4 py-3",
                        message.sender === 'user'
                          ? "bg-muted text-foreground rounded-tl-sm"
                          : "bg-gradient-to-br from-primary to-primary/80 text-primary-foreground rounded-tr-sm"
                      )}
                    >
                      <p className="whitespace-pre-wrap break-words text-sm leading-relaxed">
                        {message.content}
                      </p>
                      <p className={cn(
                        "text-[10px] mt-2",
                        message.sender === 'user' ? "text-muted-foreground" : "text-primary-foreground/60"
                      )}>
                        {message.created_at && new Date(message.created_at).toLocaleTimeString('pt-BR', {
                          hour: '2-digit',
                          minute: '2-digit'
                        })}
                      </p>
                    </div>

                    {message.sender !== 'user' && (
                      <div className="flex-shrink-0 w-8 h-8 rounded-full bg-gradient-to-br from-primary to-primary/80 flex items-center justify-center">
                        <Cloud className="h-4 w-4 text-primary-foreground" />
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Right Sidebar - User Details */}
        {activeConversation && (
          <div className="w-64 flex-shrink-0 flex flex-col">
            <div className="p-3 rounded-lg bg-muted/50 border border-border">
              {/* User Header */}
              <div className="flex items-center gap-2 mb-3">
                <div className="h-10 w-10 rounded-full bg-primary/10 flex items-center justify-center flex-shrink-0">
                  <User className="h-5 w-5 text-primary" />
                </div>
                <div className="min-w-0 flex-1">
                  <h4 className="font-semibold truncate">{activeConversation.user_name}</h4>
                  <div className="flex items-center gap-2">
                    {activeConversation.age && (
                      <span className="text-xs text-muted-foreground">{activeConversation.age} anos</span>
                    )}
                    {activeConversation.last_activity && (
                      <span className="text-xs text-primary font-medium">
                        • {formatRelativeTime(activeConversation.last_activity)}
                      </span>
                    )}
                  </div>
                </div>
              </div>

              {/* Funnel Stage Badge */}
              {activeConversation.funnel_stage && (
                <Badge
                  variant="outline"
                  className={cn(
                    "w-full justify-center mb-3 text-xs",
                    funnelStageColors[activeConversation.funnel_stage] || "bg-muted"
                  )}
                >
                  <GitBranch className="h-3 w-3 mr-1" />
                  {activeConversation.funnel_stage}
                </Badge>
              )}

              {/* Phone Number with Copy Button */}
              {activeConversation.phone && (
                <div className="flex items-center gap-2 p-2 rounded-md bg-success/10 border border-success/20 mb-3">
                  <Phone className="h-4 w-4 text-success flex-shrink-0" />
                  <span className="text-sm font-mono flex-1 truncate">{activeConversation.phone}</span>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-7 w-7 flex-shrink-0"
                    onClick={() => {
                      navigator.clipboard.writeText(activeConversation.phone!);
                      setCopiedPhone(activeConversation.phone);
                      setTimeout(() => setCopiedPhone(null), 2000);
                    }}
                  >
                    {copiedPhone === activeConversation.phone ? (
                      <Check className="h-3.5 w-3.5 text-success" />
                    ) : (
                      <Copy className="h-3.5 w-3.5 text-muted-foreground" />
                    )}
                  </Button>
                </div>
              )}

              {/* User Details */}
              <div className="space-y-2 text-xs">
                {/* Location: Where user IS from */}
                {activeConversation.city && (
                  <div className="flex items-start gap-2 text-muted-foreground">
                    <MapPin className="h-3.5 w-3.5 mt-0.5 flex-shrink-0" />
                    <div className="min-w-0">
                      <span className="text-foreground/70">Mora em:</span>
                      <p className="truncate font-medium text-foreground">{activeConversation.city}</p>
                    </div>
                  </div>
                )}

                {/* Location: Where user WANTS to study */}
                {activeConversation.location_preference && (
                  <div className="flex items-start gap-2 text-muted-foreground">
                    <Target className="h-3.5 w-3.5 mt-0.5 flex-shrink-0 text-chart-2" />
                    <div className="min-w-0">
                      <span className="text-foreground/70">Quer estudar em:</span>
                      <p className="truncate font-medium text-chart-2">{activeConversation.location_preference}</p>
                    </div>
                  </div>
                )}

                {activeConversation.education && (
                  <div className="flex items-start gap-2 text-muted-foreground">
                    <GraduationCap className="h-3.5 w-3.5 mt-0.5 flex-shrink-0" />
                    <span className="truncate">
                      {educationLabels[activeConversation.education] || activeConversation.education}
                    </span>
                  </div>
                )}

                {activeConversation.first_contact && (
                  <div className="flex items-center gap-2 text-muted-foreground">
                    <Calendar className="h-3.5 w-3.5 flex-shrink-0" />
                    <span className="truncate">
                      {formatDistanceToNow(new Date(activeConversation.first_contact), {
                        addSuffix: true,
                        locale: ptBR
                      })}
                    </span>
                  </div>
                )}

                <div className="flex items-center gap-2 text-muted-foreground">
                  <Hash className="h-3.5 w-3.5 flex-shrink-0" />
                  <span>{activeConversation.total_messages} mensagens</span>
                </div>
              </div>

              {/* Workflow Badges */}
              <div className="flex flex-wrap gap-1 mt-3">
                {activeConversation.workflow && (
                  <Badge variant="secondary" className="text-xs">
                    {workflowLabels[activeConversation.workflow] || activeConversation.workflow}
                  </Badge>
                )}
                {activeConversation.active_workflow && activeConversation.active_workflow !== activeConversation.workflow && (
                  <Badge variant="outline" className="text-xs">
                    {workflowLabels[activeConversation.active_workflow] || activeConversation.active_workflow}
                  </Badge>
                )}
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

import { useState, useRef, useEffect, useCallback } from "react";
import { Send, Loader2, Bot, User, Sparkles, Coins, AlertCircle } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useToast } from "@/hooks/use-toast";
import { supabase } from "@/integrations/supabase/client";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";

interface Message {
  role: "user" | "assistant";
  content: string;
}

const suggestedQuestions = [
  "Onde está o maior gargalo do funil?",
  "O que os usuários perguntam mais sobre SISU?",
  "Quais features devo priorizar?",
  "Por que usuários abandonam após o match?",
  "Qual o perfil dos usuários mais engajados?",
];

const CHAT_URL = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/ai-chat`;
const MAX_MESSAGES_PER_SESSION = 20;
const CONTEXT_CACHE_DURATION_MS = 5 * 60 * 1000; // 5 minutes
const MAX_HISTORY_MESSAGES = 10; // Only send last 10 messages to AI

export function AIChatPanel() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [sessionMessageCount, setSessionMessageCount] = useState(0);
  const [cachedContext, setCachedContext] = useState<string | null>(null);
  const [contextCachedAt, setContextCachedAt] = useState<number | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const { toast } = useToast();

  const messagesRemaining = MAX_MESSAGES_PER_SESSION - sessionMessageCount;
  const isSessionLimitReached = sessionMessageCount >= MAX_MESSAGES_PER_SESSION;

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages]);

  // Fetch context and cache it
  const fetchAndCacheContext = useCallback(async () => {
    // Check if cache is still valid
    if (cachedContext && contextCachedAt && Date.now() - contextCachedAt < CONTEXT_CACHE_DURATION_MS) {
      console.log("Using cached context");
      return cachedContext;
    }

    console.log("Fetching fresh context...");
    try {
      // Fetch funnel data
      const { data: funnelData } = await supabase.functions.invoke('analytics-funnel', {
        body: { includeDetails: false }
      });

      // Fetch basic stats
      const { count: totalUsers } = await supabase
        .from("user_profiles")
        .select("*", { count: "exact", head: true });

      const { count: totalMessages } = await supabase
        .from("chat_messages")
        .select("*", { count: "exact", head: true });

      const { count: totalFavorites } = await supabase
        .from("user_favorites")
        .select("*", { count: "exact", head: true });

      // Get recent user messages
      const sevenDaysAgo = new Date();
      sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);

      const { data: recentUserMessages } = await supabase
        .from("chat_messages")
        .select("content, workflow")
        .eq("sender", "user")
        .gte("created_at", sevenDaysAgo.toISOString())
        .limit(30);

      const contextData = `
## Contexto Atual do Produto

### Métricas Gerais
- Total de usuários cadastrados: ${totalUsers || 0}
- Total de mensagens: ${totalMessages || 0}
- Total de favoritos salvos: ${totalFavorites || 0}

### Funil de Conversão
${funnelData?.funnel?.map((stage: any) => `- ${stage.name}: ${stage.count} usuários (${stage.description})`).join("\n") || "Dados não disponíveis"}

### Amostra de Mensagens Recentes de Usuários (últimos 7 dias)
${recentUserMessages?.slice(0, 15).map((m: any) => `- [${m.workflow || "geral"}]: "${m.content?.substring(0, 80)}..."`).join("\n") || "Nenhuma mensagem recente"}
`;

      setCachedContext(contextData);
      setContextCachedAt(Date.now());
      return contextData;
    } catch (error) {
      console.error("Error fetching context:", error);
      return null;
    }
  }, [cachedContext, contextCachedAt]);

  const sendMessage = async (messageText: string) => {
    if (!messageText.trim() || isLoading || isSessionLimitReached) return;

    const userMsg: Message = { role: "user", content: messageText };
    setMessages((prev) => [...prev, userMsg]);
    setInput("");
    setIsLoading(true);
    setSessionMessageCount((prev) => prev + 1);

    let assistantContent = "";

    try {
      // Get cached context or fetch new one
      const context = await fetchAndCacheContext();

      // Only send last N messages to AI (saves tokens)
      const allMessages = [...messages, userMsg];
      const messagesToSend = allMessages.slice(-MAX_HISTORY_MESSAGES);

      const response = await fetch(CHAT_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}`,
        },
        body: JSON.stringify({
          messages: messagesToSend.map((m) => ({
            role: m.role,
            content: m.content,
          })),
          cachedContext: context, // Send cached context to skip backend queries
        }),
      });

      if (response.status === 429) {
        toast({
          variant: "destructive",
          title: "Limite de requisições excedido",
          description: "Aguarde alguns segundos e tente novamente.",
        });
        setIsLoading(false);
        return;
      }

      if (response.status === 402) {
        toast({
          variant: "destructive",
          title: "Créditos insuficientes",
          description: "Adicione créditos para continuar usando a AI.",
        });
        setIsLoading(false);
        return;
      }

      if (!response.ok || !response.body) {
        throw new Error("Failed to start stream");
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let textBuffer = "";
      let streamDone = false;

      // Add initial assistant message
      setMessages((prev) => [...prev, { role: "assistant", content: "" }]);

      while (!streamDone) {
        const { done, value } = await reader.read();
        if (done) break;
        textBuffer += decoder.decode(value, { stream: true });

        let newlineIndex: number;
        while ((newlineIndex = textBuffer.indexOf("\n")) !== -1) {
          let line = textBuffer.slice(0, newlineIndex);
          textBuffer = textBuffer.slice(newlineIndex + 1);

          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (line.startsWith(":") || line.trim() === "") continue;
          if (!line.startsWith("data: ")) continue;

          const jsonStr = line.slice(6).trim();
          if (jsonStr === "[DONE]") {
            streamDone = true;
            break;
          }

          try {
            const parsed = JSON.parse(jsonStr);
            const content = parsed.choices?.[0]?.delta?.content as string | undefined;
            if (content) {
              assistantContent += content;
              setMessages((prev) => {
                const updated = [...prev];
                updated[updated.length - 1] = {
                  role: "assistant",
                  content: assistantContent,
                };
                return updated;
              });
            }
          } catch {
            textBuffer = line + "\n" + textBuffer;
            break;
          }
        }
      }

      // Final flush
      if (textBuffer.trim()) {
        for (let raw of textBuffer.split("\n")) {
          if (!raw) continue;
          if (raw.endsWith("\r")) raw = raw.slice(0, -1);
          if (raw.startsWith(":") || raw.trim() === "") continue;
          if (!raw.startsWith("data: ")) continue;
          const jsonStr = raw.slice(6).trim();
          if (jsonStr === "[DONE]") continue;
          try {
            const parsed = JSON.parse(jsonStr);
            const content = parsed.choices?.[0]?.delta?.content as string | undefined;
            if (content) {
              assistantContent += content;
              setMessages((prev) => {
                const updated = [...prev];
                updated[updated.length - 1] = {
                  role: "assistant",
                  content: assistantContent,
                };
                return updated;
              });
            }
          } catch {
            /* ignore */
          }
        }
      }
    } catch (error) {
      console.error("Chat error:", error);
      toast({
        variant: "destructive",
        title: "Erro na comunicação",
        description: "Não foi possível conectar com a AI. Tente novamente.",
      });
      // Remove the empty assistant message if error occurred
      setMessages((prev) => {
        if (prev[prev.length - 1]?.role === "assistant" && !prev[prev.length - 1]?.content) {
          return prev.slice(0, -1);
        }
        return prev;
      });
    } finally {
      setIsLoading(false);
    }
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    sendMessage(input);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage(input);
    }
  };

  return (
    <div className="flex flex-col h-[600px]">
      {/* Session limit warning */}
      {isSessionLimitReached && (
        <div className="mb-4 p-3 rounded-lg bg-destructive/10 border border-destructive/20 flex items-center gap-2">
          <AlertCircle className="h-4 w-4 text-destructive" />
          <p className="text-sm text-destructive">
            Limite de {MAX_MESSAGES_PER_SESSION} mensagens por sessão atingido. Recarregue a página para iniciar uma nova conversa.
          </p>
        </div>
      )}

      <ScrollArea className="flex-1 pr-4" ref={scrollRef}>
        {messages.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full py-12">
            <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary/10 mb-4">
              <Sparkles className="h-8 w-8 text-primary" />
            </div>
            <h3 className="text-lg font-semibold mb-2">
              Converse com a AI sobre seu produto
            </h3>
            <p className="text-sm text-muted-foreground text-center max-w-md mb-6">
              Faça perguntas sobre métricas, funil de conversão, padrões de uso e
              receba sugestões de melhorias priorizadas.
            </p>
            <div className="flex flex-wrap gap-2 justify-center max-w-lg">
              {suggestedQuestions.map((question, index) => (
                <Button
                  key={index}
                  variant="outline"
                  size="sm"
                  className="text-xs"
                  onClick={() => sendMessage(question)}
                  disabled={isSessionLimitReached}
                >
                  {question}
                </Button>
              ))}
            </div>
          </div>
        ) : (
          <div className="space-y-4 py-4">
            {messages.map((message, index) => (
              <div
                key={index}
                className={`flex gap-3 ${
                  message.role === "user" ? "justify-end" : "justify-start"
                }`}
              >
                {message.role === "assistant" && (
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary/10">
                    <Bot className="h-4 w-4 text-primary" />
                  </div>
                )}
                <Card
                  className={`max-w-[80%] ${
                    message.role === "user"
                      ? "bg-primary text-primary-foreground"
                      : "bg-muted"
                  }`}
                >
                  <CardContent className="p-3">
                    <p className="text-sm whitespace-pre-wrap leading-relaxed">
                      {message.content}
                      {message.role === "assistant" && isLoading && index === messages.length - 1 && !message.content && (
                        <span className="inline-flex items-center gap-1">
                          <Loader2 className="h-3 w-3 animate-spin" />
                          Pensando...
                        </span>
                      )}
                    </p>
                  </CardContent>
                </Card>
                {message.role === "user" && (
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary">
                    <User className="h-4 w-4 text-primary-foreground" />
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </ScrollArea>

      <div className="mt-4 space-y-2">
        {/* Message counter and cost indicator */}
        <div className="flex items-center justify-between text-xs text-muted-foreground px-1">
          <div className="flex items-center gap-1">
            <span>{messagesRemaining} mensagens restantes nesta sessão</span>
          </div>
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger asChild>
                <div className="flex items-center gap-1 cursor-help">
                  <Coins className="h-3 w-3" />
                  <span>Consome créditos AI</span>
                </div>
              </TooltipTrigger>
              <TooltipContent>
                <p>Cada mensagem enviada consome créditos de AI.</p>
                <p>O contexto é cacheado por 5 minutos para economia.</p>
              </TooltipContent>
            </Tooltip>
          </TooltipProvider>
        </div>

        <form onSubmit={handleSubmit} className="flex gap-2">
          <Textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={isSessionLimitReached ? "Limite de mensagens atingido" : "Faça uma pergunta sobre seu produto..."}
            className="min-h-[60px] resize-none"
            disabled={isLoading || isSessionLimitReached}
          />
          <Button
            type="submit"
            size="icon"
            className="h-[60px] w-[60px] shrink-0"
            disabled={!input.trim() || isLoading || isSessionLimitReached}
          >
            {isLoading ? (
              <Loader2 className="h-5 w-5 animate-spin" />
            ) : (
              <Send className="h-5 w-5" />
            )}
          </Button>
        </form>
      </div>
    </div>
  );
}

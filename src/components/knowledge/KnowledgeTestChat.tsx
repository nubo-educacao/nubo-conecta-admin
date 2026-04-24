import React, { useState, useRef, useEffect } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Send, Bot, User, Loader2, MessageSquare } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";

interface Message {
    role: "user" | "assistant";
    content: string;
}

interface KnowledgeTestChatProps {
    getMarkdownContent: () => string;
    documentTitle: string;
}

export default function KnowledgeTestChat({ getMarkdownContent, documentTitle }: KnowledgeTestChatProps) {
    const [messages, setMessages] = useState<Message[]>([]);
    const [input, setInput] = useState("");
    const [isLoading, setIsLoading] = useState(false);
    const scrollRef = useRef<HTMLDivElement>(null);

    useEffect(() => {
        if (scrollRef.current) {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [messages]);

    const handleSend = async () => {
        const question = input.trim();
        if (!question || isLoading) return;
        const markdownContent = getMarkdownContent();
        if (!markdownContent.trim()) return;

        setInput("");
        setMessages((prev) => [...prev, { role: "user", content: question }]);
        setIsLoading(true);

        try {
            const { data, error } = await supabase.functions.invoke("test-knowledge", {
                body: { markdownContent, question },
            });

            if (error) throw new Error(error.message || "Erro na função");
            if (data?.error) throw new Error(data.error);

            setMessages((prev) => [
                ...prev,
                { role: "assistant", content: data.answer || "Resposta vazia." },
            ]);
        } catch (err: any) {
            setMessages((prev) => [
                ...prev,
                { role: "assistant", content: `❌ Erro: ${err.message}` },
            ]);
        } finally {
            setIsLoading(false);
        }
    };

    const handleKeyDown = (e: React.KeyboardEvent) => {
        if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            handleSend();
        }
    };

    const isEmpty = messages.length === 0;

    return (
        <div className="border rounded-lg flex flex-col h-[350px] bg-muted/30">
            {/* Header */}
            <div className="flex items-center gap-2 px-3 py-2 border-b bg-background rounded-t-lg">
                <MessageSquare className="h-4 w-4 text-primary" />
                <Label className="text-sm font-medium">Testar Conhecimento</Label>
                <span className="text-xs text-muted-foreground ml-auto">
                    Simula respostas da Cloudinha usando este documento
                </span>
            </div>

            {/* Messages */}
            <ScrollArea className="flex-1 p-3" ref={scrollRef}>
                {isEmpty ? (
                    <div className="flex flex-col items-center justify-center h-full text-center text-muted-foreground px-4">
                        <Bot className="h-8 w-8 mb-2 opacity-40" />
                        <p className="text-sm">
                            Faça uma pergunta como se fosse um estudante para testar se a Cloudinha responde corretamente com base neste documento.
                        </p>
                    </div>
                ) : (
                    <div className="space-y-3">
                        {messages.map((msg, i) => (
                            <div
                                key={i}
                                className={`flex gap-2 ${msg.role === "user" ? "justify-end" : "justify-start"}`}
                            >
                                {msg.role === "assistant" && (
                                    <div className="flex-shrink-0 w-6 h-6 rounded-full bg-primary/10 flex items-center justify-center mt-0.5">
                                        <Bot className="h-3.5 w-3.5 text-primary" />
                                    </div>
                                )}
                                <div
                                    className={`rounded-lg px-3 py-2 text-sm max-w-[85%] ${
                                        msg.role === "user"
                                            ? "bg-primary text-primary-foreground"
                                            : "bg-background border"
                                    }`}
                                >
                                    <p className="whitespace-pre-wrap">{msg.content}</p>
                                </div>
                                {msg.role === "user" && (
                                    <div className="flex-shrink-0 w-6 h-6 rounded-full bg-muted flex items-center justify-center mt-0.5">
                                        <User className="h-3.5 w-3.5" />
                                    </div>
                                )}
                            </div>
                        ))}
                        {isLoading && (
                            <div className="flex gap-2 justify-start">
                                <div className="flex-shrink-0 w-6 h-6 rounded-full bg-primary/10 flex items-center justify-center mt-0.5">
                                    <Bot className="h-3.5 w-3.5 text-primary" />
                                </div>
                                <div className="rounded-lg px-3 py-2 text-sm bg-background border">
                                    <Loader2 className="h-4 w-4 animate-spin" />
                                </div>
                            </div>
                        )}
                    </div>
                )}
            </ScrollArea>

            {/* Input */}
            <div className="flex gap-2 p-2 border-t bg-background rounded-b-lg">
                <Input
                    value={input}
                    onChange={(e) => setInput(e.target.value)}
                    onKeyDown={handleKeyDown}
                    placeholder="Ex: Quais os critérios para participar?"
                    disabled={isLoading}
                    className="text-sm"
                />
                <Button
                    size="icon"
                    onClick={handleSend}
                    disabled={isLoading || !input.trim()}
                >
                    <Send className="h-4 w-4" />
                </Button>
            </div>
        </div>
    );
}

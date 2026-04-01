import { Cloud, ArrowLeft, MessageSquare } from "lucide-react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { ChatExamplesPanel } from "@/components/analytics/ChatExamplesPanel";

export default function Conversas() {
  return (
    <div className="h-screen flex flex-col bg-background overflow-hidden">
      {/* Header - Fixed */}
      <header className="sticky top-0 z-40 backdrop-blur-md bg-background/80 border-b border-border flex-shrink-0">
        <div className="container py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <Link to="/">
                <Button variant="ghost" size="icon" className="shrink-0">
                  <ArrowLeft className="h-4 w-4" />
                </Button>
              </Link>
              <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-br from-chart-1 to-chart-2 text-primary-foreground shadow-glow">
                <MessageSquare className="h-5 w-5" />
              </div>
              <div>
                <h1 className="text-xl font-bold font-display tracking-tight">
                  Conversas Recentes
                </h1>
                <p className="text-sm text-muted-foreground">
                  Histórico de interações com usuários
                </p>
              </div>
            </div>
          </div>
        </div>
      </header>

      {/* Main Content - Takes remaining height */}
      <main className="flex-1 container py-6 overflow-hidden">
        <ChatExamplesPanel fullPage />
      </main>
    </div>
  );
}

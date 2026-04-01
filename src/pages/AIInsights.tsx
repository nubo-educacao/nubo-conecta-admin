import { useState } from "react";
import { Cloud, ArrowLeft, Sparkles, MessageSquare } from "lucide-react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { AIInsightsPanel } from "@/components/analytics/AIInsightsPanel";
import { AIChatPanel } from "@/components/analytics/AIChatPanel";

export default function AIInsights() {
  const [activeTab, setActiveTab] = useState("insights");

  return (
    <div className="min-h-screen bg-background">
      {/* Header */}
      <header className="sticky top-0 z-40 backdrop-blur-md bg-background/80 border-b border-border">
        <div className="container py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <Link to="/">
                <Button variant="ghost" size="icon" className="shrink-0">
                  <ArrowLeft className="h-4 w-4" />
                </Button>
              </Link>
              <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-chart-2 text-primary-foreground shadow-glow">
                <Cloud className="h-5 w-5" />
              </div>
              <div>
                <h1 className="text-xl font-bold font-display tracking-tight">
                  Insights com AI
                </h1>
                <p className="text-sm text-muted-foreground">
                  Análises e recomendações inteligentes
                </p>
              </div>
            </div>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="container py-6">
        <Tabs value={activeTab} onValueChange={setActiveTab} className="space-y-6">
          <TabsList className="grid w-full max-w-md grid-cols-2">
            <TabsTrigger value="insights" className="flex items-center gap-2">
              <Sparkles className="h-4 w-4" />
              Insights
            </TabsTrigger>
            <TabsTrigger value="chat" className="flex items-center gap-2">
              <MessageSquare className="h-4 w-4" />
              Chat
            </TabsTrigger>
          </TabsList>

          <TabsContent value="insights" className="space-y-6">
            <AIInsightsPanel />
          </TabsContent>

          <TabsContent value="chat">
            <AIChatPanel />
          </TabsContent>
        </Tabs>
      </main>

      {/* Footer */}
      <footer className="border-t border-border py-6 mt-12">
        <div className="container text-center text-sm text-muted-foreground">
          <p>
            Cloudinha Analytics © {new Date().getFullYear()} • Nubo Educação
          </p>
        </div>
      </footer>
    </div>
  );
}

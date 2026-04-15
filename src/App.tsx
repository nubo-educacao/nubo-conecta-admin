import { Toaster } from "@/components/ui/toaster";
import { Toaster as ToasterSonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import { AuthProvider } from "./context/AuthContext";
import AdminLayout from "./components/layout/AdminLayout";
import PartnerLayout from "./components/layout/PartnerLayout";

// Pages — Visão Geral
import Login from "./pages/Login";
import Index from "./pages/Index";
import AIInsights from "./pages/AIInsights";
import NotFound from "./pages/NotFound";
import AppCMS from "./pages/AppCMS";

// Pages — Inteligência
import Conversas from "./pages/Conversas";
import KnowledgeBase from "./pages/KnowledgeBase";
import AgentConfig from "./pages/AgentConfig";
import MatchEngine from "./pages/MatchEngine";
import AgentTelemetry from "./pages/AgentTelemetry";

// Pages — Dados Educacionais
import Calendar from "./pages/Calendar";
import Institutions from "./pages/educational-data/Institutions";
import Campus from "./pages/educational-data/Campus";
import Courses from "./pages/educational-data/Courses";
import Opportunities from "./pages/educational-data/Opportunities";

// Pages — Parceiros & B2B
import Partners from "./pages/Partners";
import PartnerSolicitations from "./pages/PartnerSolicitations";
import PartnerForms from "./pages/PartnerForms";
import PartnerUsers from "./pages/PartnerUsers";
import PartnerApplications from "./pages/PartnerApplications";
import PartnerOpportunities from "./pages/PartnerOpportunities";
import FunnelUsers from "./pages/FunnelUsers";

// Pages — Atendimento e App
import Students from "./pages/Students";
import Influencers from "./pages/Influencers";
import SeanEllis from "./pages/SeanEllis";

// Pages — Configurações
import Users from "./pages/Users";
import Support from "./pages/Support";

// Pages — Partner Portal Sandbox
import PartnerPortalForms from "./pages/PartnerPortalForms";
import PartnerDashboard from "./pages/PartnerDashboard";

const queryClient = new QueryClient();

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <Toaster />
      <ToasterSonner />
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<Login />} />

            {/* Admin Routes */}
            <Route element={<AdminLayout />}>
              {/* Visão Geral */}
              <Route path="/" element={<Index />} />
              <Route path="/ai-insights" element={<AIInsights />} />

              {/* Inteligência (Cloudinha & Match) */}
              <Route path="/conversas" element={<Conversas />} />
              <Route path="/knowledge" element={<KnowledgeBase />} />
              {/* Stub routes para Sprint 2 */}
              <Route path="/match-engine" element={<MatchEngine />} />
              <Route path="/agent-telemetry" element={<AgentTelemetry />} />
              <Route path="/agent-config" element={<AgentConfig />} />

              {/* Dados Educacionais */}
              <Route path="/institutions" element={<Institutions />} />
              <Route path="/educational/campus" element={<Campus />} />
              <Route path="/educational/courses" element={<Courses />} />
              <Route path="/educational/opportunities" element={<Opportunities />} />
              <Route path="/calendar" element={<Calendar />} />

              {/* Parceiros & B2B */}
              <Route path="/b2b-dashboard" element={<NotFound />} />
              <Route path="/partners" element={<Partners />} />
              <Route path="/partner-opportunities" element={<PartnerOpportunities />} />
              <Route path="/forms" element={<PartnerForms />} />
              <Route path="/applications" element={<PartnerApplications />} />
              <Route path="/solicitations" element={<PartnerSolicitations />} />
              <Route path="/funnel-users" element={<FunnelUsers />} />
              <Route path="/partners-users" element={<PartnerUsers />} />

              {/* Atendimento e App */}
              <Route path="/students" element={<Students />} />
              <Route path="/app-cms" element={<AppCMS />} />
              <Route path="/influencers" element={<Influencers />} />
              <Route path="/sean-ellis" element={<SeanEllis />} />

              {/* Configurações */}
              <Route path="/users" element={<Users />} />
              <Route path="/support" element={<Support />} />
            </Route>

            {/* Partner Portal Sandbox */}
            <Route element={<PartnerLayout />}>
              <Route path="/partner" element={<PartnerDashboard />} />
              <Route path="/partner/forms" element={<PartnerPortalForms />} />
            </Route>

            <Route path="*" element={<NotFound />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;

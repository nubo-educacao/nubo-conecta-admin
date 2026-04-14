import React, { useState } from "react";
import { Link, useLocation } from "react-router-dom";
import {
  LayoutDashboard,
  ChevronLeft,
  ChevronRight,
  LogOut,
  MessageSquare,
  Sparkles,
  Bot,
  ChevronDown,
  BookOpen,
  Library,
  GraduationCap,
  CalendarDays,
  Handshake,
  ClipboardList,
  FileText,
  FolderOpen,
  PieChart,
  Users,
  UserCog,
  UsersRound,
  Smartphone,
  Layers,
  Settings,
  Activity,
  Sliders,
  Bug,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { useAuth } from "@/context/AuthContext";
import { Button } from "@/components/ui/button";
import { IssueModal } from "@/components/support/IssueModal";

interface NavItemProps {
  to: string;
  icon: React.ElementType;
  label: string;
  collapsed: boolean;
  active: boolean;
}

const NavItem = ({ to, icon: Icon, label, collapsed, active }: NavItemProps) => (
  <Link
    to={to}
    className={cn(
      "flex items-center gap-3 px-3 py-2 rounded-lg transition-colors",
      "hover:bg-accent hover:text-accent-foreground",
      active ? "bg-accent text-accent-foreground font-medium" : "text-muted-foreground"
    )}
  >
    <Icon className="h-5 w-5 shrink-0" />
    {!collapsed && <span className="text-sm">{label}</span>}
  </Link>
);

type NavGroup = {
  label: string;
  icon: React.ElementType;
  permission: string;
  isGroup: true;
  items: { to: string; icon: React.ElementType; label: string; permission: string }[];
};

type NavSingle = {
  to: string;
  icon: React.ElementType;
  label: string;
  permission: string;
  isGroup?: false;
};

type NavEntry = NavGroup | NavSingle;

export default function Sidebar() {
  const [collapsed, setCollapsed] = useState(false);
  const [isIssueModalOpen, setIsIssueModalOpen] = useState(false);
  const [openGroups, setOpenGroups] = useState<Record<string, boolean>>({
    "Visão Geral": true,
    "Inteligência": false,
    "Dados Educacionais": false,
    "Parceiros & B2B": false,
    "Atendimento e App": false,
  });
  const { permissions, signOut } = useAuth();
  const location = useLocation();

  const navItems: NavEntry[] = [
    // ── Visão Geral ────────────────────────────────────────────────────────────
    {
      label: "Visão Geral",
      icon: LayoutDashboard,
      permission: "Dashboard",
      isGroup: true,
      items: [
        { to: "/", icon: LayoutDashboard, label: "Command Center", permission: "Dashboard" },
        { to: "/analytics", icon: PieChart, label: "Analytics de Produto", permission: "Dashboard" },
        { to: "/ai-insights", icon: Sparkles, label: "Insights AI", permission: "Insights AI" },
      ],
    },
    // ── Inteligência ───────────────────────────────────────────────────────────
    {
      label: "Inteligência",
      icon: Bot,
      permission: "Dashboard",
      isGroup: true,
      items: [
        { to: "/match-engine", icon: Sliders, label: "Simulador de Match", permission: "Dashboard" },
        { to: "/agent-telemetry", icon: Activity, label: "Telemetria e Erros", permission: "Dashboard" },
        { to: "/agent-config", icon: Settings, label: "Prompts & Starters", permission: "Dashboard" },
        { to: "/knowledge", icon: BookOpen, label: "Base de Conhecimento", permission: "Conhecimento" },
        { to: "/conversas", icon: MessageSquare, label: "Histórico de Conversas", permission: "Conversas" },
      ],
    },
    // ── Dados Educacionais ─────────────────────────────────────────────────────
    {
      label: "Dados Educacionais",
      icon: Library,
      permission: "Dashboard",
      isGroup: true,
      items: [
        { to: "/institutions", icon: GraduationCap, label: "Instituições & Importação", permission: "Dashboard" },
        { to: "/educational/campus", icon: LayoutDashboard, label: "Campus", permission: "Dashboard" },
        { to: "/educational/courses", icon: BookOpen, label: "Cursos", permission: "Dashboard" },
        { to: "/educational/opportunities", icon: ClipboardList, label: "Oportunidades MEC", permission: "Dashboard" },
        { to: "/calendar", icon: CalendarDays, label: "Calendário", permission: "Calendário" },
      ],
    },
    // ── Parceiros & B2B ────────────────────────────────────────────────────────
    {
      label: "Parceiros & B2B",
      icon: Handshake,
      permission: "Parceiros",
      isGroup: true,
      items: [
        { to: "/b2b-dashboard", icon: LayoutDashboard, label: "Dashboard B2B", permission: "Parceiros" },
        { to: "/partners", icon: Handshake, label: "Gestão de Parceiros", permission: "Parceiros" },
        { to: "/partner-opportunities", icon: Layers, label: "Oportunidades Parceiras", permission: "Parceiros" },
        { to: "/forms", icon: FileText, label: "Formulários Dinâmicos", permission: "Parceiros" },
        { to: "/applications", icon: FolderOpen, label: "Inscrições Recebidas", permission: "Parceiros" },
        { to: "/solicitations", icon: ClipboardList, label: "Leads Comerciais", permission: "Parceiros" },
        { to: "/funnel-users", icon: PieChart, label: "Funil de Conversão", permission: "Parceiros" },
        { to: "/partners-users", icon: Users, label: "Usuários (Parceiros)", permission: "Parceiros" },
      ],
    },
    // ── Atendimento e App ──────────────────────────────────────────────────────
    {
      label: "Atendimento e App",
      icon: Smartphone,
      permission: "Dashboard",
      isGroup: true,
      items: [
        { to: "/students", icon: GraduationCap, label: "Estudantes & Famílias", permission: "Estudantes" },
        { to: "/app-cms", icon: Layers, label: "Vitrine & Destaques", permission: "Dashboard" },
        { to: "/influencers", icon: UsersRound, label: "Influencers", permission: "Influencers" },
        { to: "/sean-ellis", icon: PieChart, label: "Sean Ellis Score", permission: "Sean Ellis Score" },
      ],
    },
    // ── Configurações ──────────────────────────────────────────────────────────
    { to: "/users", icon: UserCog, label: "Usuários", permission: "Controle de usuários" },
    { to: "/support", icon: Bug, label: "Suporte e Bugs", permission: "Dashboard" },
  ];

  const toggleGroup = (label: string) => {
    if (collapsed) return;
    setOpenGroups((prev) => ({ ...prev, [label]: !prev[label] }));
  };

  const renderNavItem = (item: NavEntry) => {
    if (item.isGroup) {
      const allowedItems = item.items.filter((sub) => permissions.includes(sub.permission));
      if (allowedItems.length === 0) return null;

      const isChildActive = allowedItems.some((sub) => location.pathname === sub.to);
      const isOpen = openGroups[item.label] ?? false;

      return (
        <div key={item.label} className="space-y-1">
          <button
            onClick={() => toggleGroup(item.label)}
            className={cn(
              "w-full flex items-center justify-between gap-3 px-3 py-2 rounded-lg transition-colors",
              isChildActive
                ? "text-primary font-medium"
                : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
            )}
          >
            <div className="flex items-center gap-3">
              <item.icon className={cn("h-5 w-5 shrink-0", isChildActive && "text-primary")} />
              {!collapsed && <span className="text-sm">{item.label}</span>}
            </div>
            {!collapsed && (
              <ChevronDown
                className={cn("h-4 w-4 transition-transform", isOpen ? "rotate-0" : "-rotate-90")}
              />
            )}
          </button>
          {!collapsed && isOpen && (
            <div className="pl-6 space-y-1 border-l ml-5 border-border/50">
              {allowedItems.map((sub) => (
                <NavItem
                  key={sub.to}
                  to={sub.to}
                  icon={sub.icon}
                  label={sub.label}
                  collapsed={collapsed}
                  active={location.pathname === sub.to}
                />
              ))}
            </div>
          )}
        </div>
      );
    }

    if (!permissions.includes(item.permission)) return null;

    const singleItem = item as NavSingle;
    return (
      <NavItem
        key={singleItem.to}
        to={singleItem.to}
        icon={singleItem.icon}
        label={singleItem.label}
        collapsed={collapsed}
        active={location.pathname === singleItem.to}
      />
    );
  };

  return (
    <div
      className={cn(
        "flex flex-col border-r bg-card transition-all duration-300 h-full",
        collapsed ? "w-16" : "w-64"
      )}
    >
      <div className="flex h-16 items-center justify-between px-4 border-b">
        {!collapsed && <span className="font-bold text-lg">Nubo Admin</span>}
        <Button
          variant="ghost"
          size="icon"
          onClick={() => setCollapsed(!collapsed)}
          className="h-8 w-8"
        >
          {collapsed ? <ChevronRight className="h-4 w-4" /> : <ChevronLeft className="h-4 w-4" />}
        </Button>
      </div>

      <nav className="flex-1 space-y-1 p-2 overflow-y-auto">
        {navItems.map(renderNavItem)}
      </nav>

      <div className="p-2 border-t flex flex-col gap-1">
        <Button
          variant="ghost"
          className={cn(
            "w-full flex items-center gap-3 px-3 py-2 text-muted-foreground hover:text-destructive",
            collapsed ? "justify-center" : "justify-start"
          )}
          onClick={() => signOut()}
        >
          <LogOut className="h-5 w-5" />
          {!collapsed && <span className="text-sm">Sair</span>}
        </Button>
      </div>
      <IssueModal isOpen={isIssueModalOpen} onClose={() => setIsIssueModalOpen(false)} />
    </div>
  );
}

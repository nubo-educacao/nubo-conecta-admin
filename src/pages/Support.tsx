import React, { useState } from "react";
import { format } from "date-fns";
import { PlusCircle, Search, Bug, Lightbulb, Ticket, AlertCircle, ChevronDown, CheckCircle2, Clock } from "lucide-react";
import { useGetIssues, useUpdateIssueStatus } from "@/hooks/useGithubIssues";
import { IssueModal } from "@/components/support/IssueModal";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

const getRepoName = (url: string) => {
  if (!url) return '';
  const parts = url.split('/');
  return parts[parts.length - 1];
};

export default function Support() {
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const { data: issues, isLoading, isError, error } = useGetIssues();
  const { mutate: updateStatus, isPending: isUpdating } = useUpdateIssueStatus();

  const handleStatusChange = (issue: any, action: 'abrir' | 'aprovar' | 'concluir') => {
    updateStatus({
      issueNumber: issue.number,
      repo: getRepoName(issue.repository_url),
      action
    });
  };

  const filteredIssues = Array.isArray(issues) 
    ? issues.filter((issue: any) => issue.title?.toLowerCase().includes(searchTerm.toLowerCase()))
    : [];

  const errorMessage = isError ? (error as Error).message : (issues as any)?.error || (issues as any)?.message;

  return (
    <div className="flex-1 space-y-4 p-8 pt-6 animate-in fade-in slide-in-from-bottom-2">
      <div className="flex items-center justify-between space-y-2">
        <h2 className="text-3xl font-bold tracking-tight">Central de Bugs & Sugestões</h2>
        <div className="flex items-center space-x-2">
          <Button onClick={() => setIsModalOpen(true)}>
            <PlusCircle className="mr-2 h-4 w-4" />
            Nova Issue
          </Button>
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Tickets Abertos</CardTitle>
            <Ticket className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{isLoading ? <Skeleton className="h-8 w-16" /> : issues?.length || 0}</div>
            <p className="text-xs text-muted-foreground">Última extração do GitHub</p>
          </CardContent>
        </Card>
      </div>

      <div className="flex items-center space-x-2">
        <Search className="h-4 w-4 text-muted-foreground" />
        <Input
          placeholder="Buscar issues..."
          className="w-[150px] lg:w-[250px]"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
      </div>

      <div className="rounded-md border">
        {isLoading ? (
          <div className="p-4 space-y-4">
            <Skeleton className="h-12 w-full" />
            <Skeleton className="h-12 w-full" />
          </div>
        ) : errorMessage ? (
          <div className="p-8 text-center text-red-500">
            <AlertCircle className="h-8 w-8 mx-auto mb-2" />
            <p>Erro do GitHub: {errorMessage}</p>
          </div>
        ) : filteredIssues.length === 0 ? (
          <div className="p-8 text-center text-muted-foreground">
            <p>Nenhuma issue encontrada.</p>
          </div>
        ) : (
          <div className="divide-y">
            {filteredIssues.map((issue: any) => {
              const isClosed = issue.state === 'closed';
              const isConcluido = issue.labels?.some((l:any) => l.name === 'status:concluido');
              const isApproved = issue.labels?.some((l:any) => l.name === 'status:aprovar');
              const statusName = isClosed ? "Encerrado" : isConcluido ? "Concluído" : isApproved ? "Para Validação" : "Em Aberto";
              const statusColor = isClosed ? "bg-slate-800" : isConcluido ? "bg-slate-500" : isApproved ? "bg-yellow-500 text-black" : "bg-blue-500";

              return (
                <div key={issue.id} className="flex p-4 items-center justify-between hover:bg-muted/50 transition-colors">
                  <div className="space-y-1">
                    <p className="text-sm font-medium leading-none flex items-center gap-2">
                      {issue.labels?.some((l:any) => l.name === 'bug') ? <Bug className="h-4 w-4 text-red-500"/> : <Lightbulb className="h-4 w-4 text-green-500"/>}
                      {issue.title}
                      <Badge variant="secondary" className="ml-2 text-[10px]">{getRepoName(issue.repository_url)}</Badge>
                    </p>
                    <p className="text-sm text-muted-foreground">
                      #{issue.number} aberta por {issue.user.login} em {format(new Date(issue.created_at), 'dd/MM/yyyy')}
                    </p>
                  </div>
                  <div className="flex items-center gap-4">
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button variant="outline" size="sm" className="h-8 border-dashed" disabled={isUpdating}>
                          <Badge className={`${statusColor} hover:${statusColor} mr-2`}>{statusName}</Badge>
                          Mudar <ChevronDown className="ml-1 h-3 w-3" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem onClick={() => handleStatusChange(issue, 'abrir')}>
                          <Clock className="mr-2 h-4 w-4" /> Em Aberto (Dev Resolve)
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => handleStatusChange(issue, 'aprovar')}>
                          <CheckCircle2 className="mr-2 h-4 w-4 text-yellow-500" /> Para Validação (PO)
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => handleStatusChange(issue, 'concluir')}>
                          <CheckCircle2 className="mr-2 h-4 w-4 text-slate-500" /> Concluído (Cron Fecha)
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>

                    <a
                      href={issue.html_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-sm text-blue-500 hover:underline"
                    >
                      Ver no GitHub
                    </a>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      <IssueModal isOpen={isModalOpen} onClose={() => setIsModalOpen(false)} />
    </div>
  );
}

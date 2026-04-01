import { useMemo } from "react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";
import type { PartnerRedirectUser } from "@/services/partnerPortalService";

interface RedirectUsersTableProps {
  redirectUsers: PartnerRedirectUser[];
}

export default function RedirectUsersTable({ redirectUsers }: RedirectUsersTableProps) {
  const uniqueUsers = useMemo(() => {
    if (!redirectUsers) return [];
    
    const userMap = new Map<string, PartnerRedirectUser>();
    
    // Group by WhatsApp if available, or full_name
    redirectUsers.forEach((user) => {
      const key = user.whatsapp || user.full_name;
      const existing = userMap.get(key);
      
      // Keep only the most recent click for each user
      if (!existing || new Date(user.created_at) > new Date(existing.created_at)) {
        userMap.set(key, user);
      }
    });
    
    // Convert back to array and sort by most recent click
    return Array.from(userMap.values()).sort(
      (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
    );
  }, [redirectUsers]);

  if (!redirectUsers || redirectUsers.length === 0) {
    return null;
  }

  return (
    <Card className="mt-6">
      <CardHeader>
        <CardTitle className="text-lg">Redirecionamentos Externos</CardTitle>
        <CardDescription>
          {uniqueUsers.length} usuários únicos que clicaram para se candidatar externamente
        </CardDescription>
      </CardHeader>
      <CardContent>
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Nome</TableHead>
                <TableHead>WhatsApp</TableHead>
                <TableHead>URL de Destino</TableHead>
                <TableHead className="text-right">Data do Último Clique</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {uniqueUsers.map((user, idx) => (
                <TableRow key={`${generateUserKey(user, idx)}`}>
                  <TableCell className="font-medium">{user.full_name || "—"}</TableCell>
                  <TableCell>{user.whatsapp || "—"}</TableCell>
                  <TableCell className="text-muted-foreground whitespace-nowrap truncate max-w-[200px]" title={user.redirect_url}>
                    {user.redirect_url || "—"}
                  </TableCell>
                  <TableCell className="text-right">
                    {format(new Date(user.created_at), "dd/MM/yyyy HH:mm", { locale: ptBR })}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </CardContent>
    </Card>
  );
}

function generateUserKey(u: PartnerRedirectUser, idx: number) {
  return `${u.full_name}-${u.whatsapp}-${idx}`;
}


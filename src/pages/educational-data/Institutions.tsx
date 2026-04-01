import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { getInstitutions } from "@/services/educationalDataService";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";

export default function Institutions() {
    const [page, setPage] = useState(0);
    const [search, setSearch] = useState("");
    const [searchInput, setSearchInput] = useState("");
    const pageSize = 20;

    const { data, isLoading, isError } = useQuery({
        queryKey: ["institutions", page, pageSize, search],
        queryFn: () => getInstitutions(page, pageSize, search),
    });

    const handleSearch = () => {
        setPage(0);
        setSearch(searchInput);
    };

    return (
        <div className="p-6 space-y-6">
            <div>
                <h1 className="text-3xl font-bold tracking-tight">Instituições</h1>
                <p className="text-muted-foreground">Visualize as instituições do Ministério da Educação.</p>
            </div>

            <div className="flex items-center gap-2 max-w-sm">
                <Input 
                    placeholder="Buscar por nome..." 
                    value={searchInput}
                    onChange={(e) => setSearchInput(e.target.value)}
                    onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
                />
                <Button variant="outline" size="icon" onClick={handleSearch}>
                    <Search className="h-4 w-4" />
                </Button>
            </div>

            <div className="rounded-md border bg-white relative min-h-[400px]">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>Nome</TableHead>
                            <TableHead>Código Externo (MEC)</TableHead>
                            <TableHead>Criado em</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {isLoading ? (
                            Array.from({ length: 5 }).map((_, i) => (
                                <TableRow key={i}>
                                    <TableCell><Skeleton className="h-4 w-[250px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                </TableRow>
                            ))
                        ) : isError ? (
                            <TableRow>
                                <TableCell colSpan={3} className="h-24 text-center text-red-500">
                                    Erro ao carregar instituições.
                                </TableCell>
                            </TableRow>
                        ) : data?.data?.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={3} className="h-24 text-center">
                                    Nenhuma instituição encontrada.
                                </TableCell>
                            </TableRow>
                        ) : (
                            data?.data?.map((inst: any) => (
                                <TableRow key={inst.id}>
                                    <TableCell className="font-medium">{inst.name}</TableCell>
                                    <TableCell>{inst.external_code || "-"}</TableCell>
                                    <TableCell>{new Date(inst.created_at).toLocaleDateString("pt-BR")}</TableCell>
                                </TableRow>
                            ))
                        )}
                    </TableBody>
                </Table>
            </div>

            <div className="flex items-center justify-between">
                <div className="text-sm text-muted-foreground">
                    {data?.count !== undefined && (
                        <span>Total de {data.count} registros</span>
                    )}
                </div>
                <div className="flex items-center gap-2">
                    <Button 
                        variant="outline" 
                        size="sm" 
                        onClick={() => setPage(p => Math.max(0, p - 1))}
                        disabled={page === 0 || isLoading}
                    >
                        <ChevronLeft className="h-4 w-4 mr-1" /> Anterior
                    </Button>
                    <div className="text-sm px-2">Página {page + 1}</div>
                    <Button 
                        variant="outline" 
                        size="sm" 
                        onClick={() => setPage(p => p + 1)}
                        disabled={!data?.data || data.data.length < pageSize || isLoading}
                    >
                        Próxima <ChevronRight className="h-4 w-4 ml-1" />
                    </Button>
                </div>
            </div>
        </div>
    );
}

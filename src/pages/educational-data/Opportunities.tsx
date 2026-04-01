import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { getOpportunities } from "@/services/educationalDataService";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";

export default function Opportunities() {
    const [page, setPage] = useState(0);
    const [search, setSearch] = useState("");
    const [searchInput, setSearchInput] = useState("");
    const pageSize = 20;

    const { data, isLoading, isError } = useQuery({
        queryKey: ["opportunities", page, pageSize, search],
        queryFn: () => getOpportunities(page, pageSize, search),
    });

    const handleSearch = () => {
        setPage(0);
        setSearch(searchInput);
    };

    return (
        <div className="p-6 space-y-6">
            <div>
                <h1 className="text-3xl font-bold tracking-tight">Oportunidades</h1>
                <p className="text-muted-foreground">Visualize as oportunidades de acesso (vagas em cursos).</p>
            </div>

            <div className="flex items-center gap-2 max-w-sm">
                <Input 
                    placeholder="Buscar por curso na oportunidade..." 
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
                            <TableHead>Curso</TableHead>
                            <TableHead>Turno</TableHead>
                            <TableHead>Bolsa / Cota</TableHead>
                            <TableHead>Nota Corte</TableHead>
                            <TableHead>Ano/Semestre</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {isLoading ? (
                            Array.from({ length: 5 }).map((_, i) => (
                                <TableRow key={i}>
                                    <TableCell><Skeleton className="h-4 w-[250px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[150px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[80px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                </TableRow>
                            ))
                        ) : isError ? (
                            <TableRow>
                                <TableCell colSpan={5} className="h-24 text-center text-red-500">
                                    Erro ao carregar oportunidades.
                                </TableCell>
                            </TableRow>
                        ) : data?.data?.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={5} className="h-24 text-center">
                                    Nenhuma oportunidade encontrada.
                                </TableCell>
                            </TableRow>
                        ) : (
                            data?.data?.map((item: any) => (
                                <TableRow key={item.id}>
                                    <TableCell className="font-medium text-wrap max-w-[250px]">{item.course_name}</TableCell>
                                    <TableCell>{item.shift || "-"}</TableCell>
                                    <TableCell>
                                        <div className="flex flex-col gap-1">
                                            {item.scholarship_type && (
                                                <Badge variant="secondary" className="w-fit">{item.scholarship_type}</Badge>
                                            )}
                                        </div>
                                    </TableCell>
                                    <TableCell>{item.cutoff_score || "-"}</TableCell>
                                    <TableCell>{item.year} / {item.semester}</TableCell>
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

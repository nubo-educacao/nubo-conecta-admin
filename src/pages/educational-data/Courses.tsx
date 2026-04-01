import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { getCourses } from "@/services/educationalDataService";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";

export default function Courses() {
    const [page, setPage] = useState(0);
    const [search, setSearch] = useState("");
    const [searchInput, setSearchInput] = useState("");
    const pageSize = 20;

    const { data, isLoading, isError } = useQuery({
        queryKey: ["courses", page, pageSize, search],
        queryFn: () => getCourses(page, pageSize, search),
    });

    const handleSearch = () => {
        setPage(0);
        setSearch(searchInput);
    };

    return (
        <div className="p-6 space-y-6">
            <div>
                <h1 className="text-3xl font-bold tracking-tight">Cursos</h1>
                <p className="text-muted-foreground">Visualize os cursos de graduação ofertados.</p>
            </div>

            <div className="flex items-center gap-2 max-w-sm">
                <Input 
                    placeholder="Buscar por nome do curso..." 
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
                            <TableHead>Nome do Curso</TableHead>
                            <TableHead>Código do Curso</TableHead>
                            <TableHead>Campus</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {isLoading ? (
                            Array.from({ length: 5 }).map((_, i) => (
                                <TableRow key={i}>
                                    <TableCell><Skeleton className="h-4 w-[250px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[120px]" /></TableCell>
                                    <TableCell><Skeleton className="h-4 w-[200px]" /></TableCell>
                                </TableRow>
                            ))
                        ) : isError ? (
                            <TableRow>
                                <TableCell colSpan={3} className="h-24 text-center text-red-500">
                                    Erro ao carregar cursos.
                                </TableCell>
                            </TableRow>
                        ) : data?.data?.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={3} className="h-24 text-center">
                                    Nenhum curso encontrado.
                                </TableCell>
                            </TableRow>
                        ) : (
                            data?.data?.map((item: any) => (
                                <TableRow key={item.id}>
                                    <TableCell className="font-medium">{item.course_name}</TableCell>
                                    <TableCell>{item.course_code || "-"}</TableCell>
                                    <TableCell>{item.campus_name}</TableCell>
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

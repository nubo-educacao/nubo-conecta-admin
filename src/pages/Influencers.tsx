import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Plus, Users, Award, TrendingUp, Loader2, Eye, Link as LinkIcon, ArrowUpDown, ArrowUp, ArrowDown } from "lucide-react";

import { StatCard } from "@/components/analytics/StatCard";
import InfluencerModal from "@/components/influencers/InfluencerModal";
import AffiliatesModal from "@/components/influencers/AffiliatesModal";
import TrackableLinkModal from "@/components/influencers/TrackableLinkModal";
import { toast } from "sonner";


interface Influencer {
    id: string;
    name: string;
    code: string;
    affiliate_count: number;
}

export default function Influencers() {
    const [influencers, setInfluencers] = useState<Influencer[]>([]);
    const [loading, setLoading] = useState(true);
    const [sortBy, setSortBy] = useState("name");
    const [sortOrder, setSortOrder] = useState("asc");
    const [modalOpen, setModalOpen] = useState(false);
    // ... rest
    const [affiliatesModalOpen, setAffiliatesModalOpen] = useState(false);
    const [linkModalOpen, setLinkModalOpen] = useState(false);
    const [selectedInfluencer, setSelectedInfluencer] = useState<{ code: string; name: string } | null>(null);

    // Stats
    const [totalAffiliates, setTotalAffiliates] = useState(0);
    const [bestInfluencer, setBestInfluencer] = useState<string | null>(null);
    const [avgAffiliates, setAvgAffiliates] = useState(0);

    const fetchData = async () => {
        setLoading(true);
        try {
            // Fetch influencer stats directly via RPC
            const { data: processedInfluencers, error: influencersError } = await supabase.rpc("get_influencer_stats" as any, {
                p_sort_by: sortBy,
                p_sort_order: sortOrder
            });

            if (influencersError) throw influencersError;
            setInfluencers((processedInfluencers as any) || []);

            // Fetch dashboard stats via RPC
            const { data: stats, error: statsError } = await supabase.rpc("get_influencer_dashboard_stats" as any);

            if (statsError) throw statsError;

            if (stats) {
                const s = stats as any;
                setTotalAffiliates(s.total_affiliates);
                setBestInfluencer(s.best_influencer);
                setAvgAffiliates(s.avg_affiliates);
            }
        } catch (error: any) {


            toast.error("Erro ao carregar dados: " + error.message);
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        fetchData();
    }, [sortBy, sortOrder]);

    const handleSort = (field: string) => {
        if (sortBy === field) {
            setSortOrder(sortOrder === "asc" ? "desc" : "asc");
        } else {
            setSortBy(field);
            setSortOrder("asc");
        }
    };

    const handleViewAffiliates = (influencer: Influencer) => {
        setSelectedInfluencer({ code: influencer.code, name: influencer.name });
        setAffiliatesModalOpen(true);
    };

    return (
        <div className="space-y-6">
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Influencers</h1>
                    <p className="text-muted-foreground">
                        Gerencie seus parceiros e acompanhe o crescimento de usuários afiliados.
                    </p>
                </div>

                <Button onClick={() => setModalOpen(true)} className="gap-2">
                    <Plus className="h-4 w-4" /> Adicionar Influencer
                </Button>
            </div>

            <div className="grid gap-4 md:grid-cols-3">
                <StatCard
                    title="Total de Afiliados"
                    value={totalAffiliates}
                    icon={Users}
                    tooltip="Total de usuários que se cadastraram via link de influencer"
                />
                <StatCard
                    title="Melhor Influencer"
                    value={bestInfluencer || "Carregando..."}
                    icon={Award}
                    variant="success"
                    tooltip="Influencer com o maior número de usuários afiliados"
                />
                <StatCard
                    title="Afiliados por Influencer"
                    value={avgAffiliates.toFixed(1)}
                    icon={TrendingUp}
                    variant="warning"
                    tooltip="Média de novos usuários por influencer cadastrado"
                />
            </div>

            <div className="border rounded-lg bg-card shadow-sm">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead
                                className="cursor-pointer hover:bg-muted/50 transition-colors"
                                onClick={() => handleSort("name")}
                            >
                                <div className="flex items-center">
                                    Nome
                                    {sortBy === "name" ? (
                                        sortOrder === "asc" ? <ArrowUp className="ml-2 h-4 w-4 text-primary" /> : <ArrowDown className="ml-2 h-4 w-4 text-primary" />
                                    ) : (
                                        <ArrowUpDown className="ml-2 h-4 w-4 text-muted-foreground/30" />
                                    )}
                                </div>
                            </TableHead>
                            <TableHead
                                className="cursor-pointer hover:bg-muted/50 transition-colors"
                                onClick={() => handleSort("code")}
                            >
                                <div className="flex items-center">
                                    Código
                                    {sortBy === "code" ? (
                                        sortOrder === "asc" ? <ArrowUp className="ml-2 h-4 w-4 text-primary" /> : <ArrowDown className="ml-2 h-4 w-4 text-primary" />
                                    ) : (
                                        <ArrowUpDown className="ml-2 h-4 w-4 text-muted-foreground/30" />
                                    )}
                                </div>
                            </TableHead>
                            <TableHead
                                className="cursor-pointer hover:bg-muted/50 transition-colors text-center"
                                onClick={() => handleSort("affiliate_count")}
                            >
                                <div className="flex items-center justify-center">
                                    Total Afiliados
                                    {sortBy === "affiliate_count" ? (
                                        sortOrder === "asc" ? <ArrowUp className="ml-2 h-4 w-4 text-primary" /> : <ArrowDown className="ml-2 h-4 w-4 text-primary" />
                                    ) : (
                                        <ArrowUpDown className="ml-2 h-4 w-4 text-muted-foreground/30" />
                                    )}
                                </div>
                            </TableHead>
                            <TableHead className="text-right">Ações</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {loading ? (
                            <TableRow>
                                <TableCell colSpan={4} className="text-center py-10">
                                    <Loader2 className="h-8 w-8 animate-spin mx-auto text-muted-foreground" />
                                </TableCell>
                            </TableRow>
                        ) : influencers.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={4} className="text-center py-10 text-muted-foreground">
                                    Nenhum influencer encontrado.
                                </TableCell>
                            </TableRow>
                        ) : (
                            influencers.map((inf) => (
                                <TableRow key={inf.id}>
                                    <TableCell className="font-medium">{inf.name}</TableCell>
                                    <TableCell>
                                        <code className="bg-muted px-1.5 py-0.5 rounded text-xs">
                                            {inf.code}
                                        </code>
                                    </TableCell>
                                    <TableCell className="text-center font-semibold">
                                        {inf.affiliate_count}
                                    </TableCell>
                                    <TableCell className="text-right">
                                        <div className="flex justify-end gap-2">
                                            <Button
                                                variant="ghost"
                                                size="icon"
                                                onClick={() => {
                                                    setSelectedInfluencer({ code: inf.code, name: inf.name });
                                                    setLinkModalOpen(true);
                                                }}
                                                title="Gerar Link"
                                            >
                                                <LinkIcon className="h-4 w-4" />
                                            </Button>

                                            <Button
                                                variant="ghost"
                                                size="icon"
                                                onClick={() => handleViewAffiliates(inf)}
                                                title="Ver Afiliados"
                                            >
                                                <Eye className="h-4 w-4" />
                                            </Button>
                                        </div>
                                    </TableCell>

                                </TableRow>
                            ))
                        )}
                    </TableBody>
                </Table>
            </div>

            <InfluencerModal
                open={modalOpen}
                onOpenChange={setModalOpen}
                onSuccess={fetchData}
            />

            <AffiliatesModal
                open={affiliatesModalOpen}
                onOpenChange={setAffiliatesModalOpen}
                influencerCode={selectedInfluencer?.code || null}
                influencerName={selectedInfluencer?.name || null}
            />

            <TrackableLinkModal
                open={linkModalOpen}
                onOpenChange={setLinkModalOpen}
                influencerCode={selectedInfluencer?.code || null}
            />
        </div>

    );
}

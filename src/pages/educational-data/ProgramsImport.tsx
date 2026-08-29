import { useSearchParams } from "react-router-dom";
import Programs from "@/pages/Programs";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import DataPipeline from "./DataPipeline";
import EtlProcessingLogs from "./EtlProcessingLogs";

// Um único nível de abas: antes "Importação" abria outro TabsList dentro dela
// (abas dentro de abas). Pipeline e logs agora são irmãos de "Programas".
const TABS = ["programs", "import", "logs"] as const;
type TabValue = (typeof TABS)[number];

export default function ProgramsImport() {
  const [searchParams, setSearchParams] = useSearchParams();
  const requested = searchParams.get("tab");
  const activeTab: TabValue = TABS.includes(requested as TabValue) ? (requested as TabValue) : "programs";

  return (
    <div className="space-y-5 p-4 sm:p-6">
      <div className="rounded-2xl border border-sky-100 bg-gradient-to-r from-sky-50 via-white to-white px-5 py-4">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-700">Dados educacionais</p>
        <h1 className="mt-1 text-2xl font-semibold text-slate-900">Programas &amp; Importação</h1>
        <p className="mt-1 max-w-3xl text-sm text-slate-600">
          Gerencie ciclos MEC e acompanhe uploads, processamento e histórico do pipeline no mesmo contexto.
        </p>
      </div>

      <Tabs
        value={activeTab}
        onValueChange={(tab) => setSearchParams(tab === "programs" ? {} : { tab })}
      >
        <TabsList aria-label="Seções de programas e importação">
          <TabsTrigger value="programs">Programas</TabsTrigger>
          <TabsTrigger value="import">Importação (ETL)</TabsTrigger>
          <TabsTrigger value="logs">Logs de Processamento</TabsTrigger>
        </TabsList>
        <TabsContent value="programs" className="mt-4">
          <Programs />
        </TabsContent>
        <TabsContent value="import" className="mt-4">
          <DataPipeline />
        </TabsContent>
        <TabsContent value="logs" className="mt-4">
          <EtlProcessingLogs />
        </TabsContent>
      </Tabs>
    </div>
  );
}

import { useSearchParams } from "react-router-dom";
import Programs from "@/pages/Programs";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import DataPipeline from "./DataPipeline";
import Institutions from "./Institutions";

export default function ProgramsImport() {
  const [searchParams, setSearchParams] = useSearchParams();
  const activeTab = searchParams.get("tab") === "import" ? "import" : "programs";

  return (
    <div className="space-y-5 p-4 sm:p-6">
      <div className="rounded-2xl border border-sky-100 bg-gradient-to-r from-sky-50 via-white to-white px-5 py-4">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-700">Dados educacionais</p>
        <h1 className="mt-1 text-2xl font-semibold text-slate-900">Programas & Importação</h1>
        <p className="mt-1 max-w-3xl text-sm text-slate-600">
          Gerencie ciclos MEC e acompanhe uploads, processamento e histórico do pipeline no mesmo contexto.
        </p>
      </div>

      <Tabs
        value={activeTab}
        onValueChange={(tab) => setSearchParams(tab === "import" ? { tab } : {})}
      >
        <TabsList aria-label="Seções de programas e importação">
          <TabsTrigger value="programs">Programas</TabsTrigger>
          <TabsTrigger value="import">Importação</TabsTrigger>
        </TabsList>
        <TabsContent value="programs" className="mt-4">
          <Programs />
        </TabsContent>
        <TabsContent value="import" className="mt-4 space-y-6">
          <DataPipeline />
          <Institutions embedded initialTab="import" showCatalog={false} />
        </TabsContent>
      </Tabs>
    </div>
  );
}

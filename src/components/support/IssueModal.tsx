import React, { useState } from "react";
import { useForm, Controller } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { useCreateIssue } from "@/hooks/useGithubIssues";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { toast } from "sonner";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";

const formSchema = z.object({
  title: z.string().min(5, "O título deve ter no mínimo 5 caracteres").max(100),
  version: z.string().min(1, "Obrigatório"),
  application: z.string().min(1, "Obrigatório"),
  type: z.enum(["bug", "feature"], {
    required_error: "Selecione o tipo de issue",
  }),
  // Bug fields
  actualBehavior: z.string().optional(),
  expectedBehavior: z.string().optional(),
  stepsToReproduce: z.string().optional(),
  severity: z.string().optional(),
  // Feature fields
  problemOpportunity: z.string().optional(),
  proposedSolution: z.string().optional(),
  expectedImpact: z.string().optional(),
}).superRefine((data, ctx) => {
  if (data.type === "bug") {
    if (!data.actualBehavior) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["actualBehavior"] });
    if (!data.expectedBehavior) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["expectedBehavior"] });
    if (!data.stepsToReproduce) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["stepsToReproduce"] });
    if (!data.severity) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["severity"] });
  } else if (data.type === "feature") {
    if (!data.problemOpportunity) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["problemOpportunity"] });
    if (!data.proposedSolution) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["proposedSolution"] });
    if (!data.expectedImpact) ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Obrigatório", path: ["expectedImpact"] });
  }
});

type FormData = z.infer<typeof formSchema>;

export function IssueModal({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) {
  const [attachment, setAttachment] = useState<File | null>(null);
  const { mutateAsync: createIssue, isPending } = useCreateIssue();
  
  const {
    register,
    handleSubmit,
    control,
    watch,
    reset,
    formState: { errors },
  } = useForm<FormData>({
    resolver: zodResolver(formSchema),
    defaultValues: {
      type: "bug",
      version: "",
      application: "",
      title: "",
    },
  });

  const issueType = watch("type");

  const onSubmit = async (data: FormData) => {
    try {
      let bodyText = "";
      if (data.type === "bug") {
        bodyText = `### Comportamento Atual\n${data.actualBehavior}\n\n### Comportamento Esperado\n${data.expectedBehavior}\n\n### Passos para Reproduzir\n${data.stepsToReproduce}\n\n### Severidade\n${data.severity}`;
      } else {
        bodyText = `### Problema / Oportunidade\n${data.problemOpportunity}\n\n### Solução Proposta\n${data.proposedSolution}\n\n### Impacto Esperado\n${data.expectedImpact}`;
      }

      if (attachment) {
        const fileExt = attachment.name.split('.').pop();
        const fileName = `${Math.random()}.${fileExt}`;
        const filePath = `${fileName}`;

        const { error: uploadError } = await supabase.storage
          .from('issues-attachments')
          .upload(filePath, attachment);

        if (!uploadError) {
          const { data: { publicUrl } } = supabase.storage
            .from('issues-attachments')
            .getPublicUrl(filePath);
          
          bodyText += `\n\n**Anexo:**\n[![Anexo](${publicUrl})](${publicUrl})`;
        }
      }

      await createIssue({
        application: data.application,
        version: data.version,
        title: data.title,
        type: data.type,
        body: bodyText,
      });

      toast.success("Issue criada com sucesso no GitHub!");
      reset();
      setAttachment(null);
      onClose();
    } catch (error) {
      toast.error(`Erro ao criar issue: ${(error as Error).message}`);
    }
  };

  return (
    <Dialog open={isOpen} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-[600px] max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Abrir nova Issue ou Sugestão</DialogTitle>
          <DialogDescription>
            Preencha os detalhes técnicos para que nosso time possa priorizar a demanda.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label>Tipo de Relato</Label>
              <Controller
                name="type"
                control={control}
                render={({ field }) => (
                  <Select onValueChange={field.onChange} defaultValue={field.value}>
                    <SelectTrigger>
                      <SelectValue placeholder="Selecione o tipo" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="bug">Reportar Bug</SelectItem>
                      <SelectItem value="feature">Sugerir Melhoria</SelectItem>
                    </SelectContent>
                  </Select>
                )}
              />
              {errors.type && <p className="text-sm text-red-500">{errors.type.message}</p>}
            </div>
            
            <div className="space-y-2">
              <Label>Aplicações</Label>
              <Controller
                name="application"
                control={control}
                render={({ field }) => (
                  <Select onValueChange={field.onChange} defaultValue={field.value}>
                    <SelectTrigger>
                      <SelectValue placeholder="Selecione o app" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="nubo-conecta-app">App (Estudante)</SelectItem>
                      <SelectItem value="nubo-hub-admin">Admin Central (Hub)</SelectItem>
                      <SelectItem value="nubo-conecta-admin">Admin (Instituições)</SelectItem>
                      <SelectItem value="cloudinha-conecta-agent">Cloudinha (IA)</SelectItem>
                    </SelectContent>
                  </Select>
                )}
              />
              {errors.application && <p className="text-sm text-red-500">{errors.application.message}</p>}
            </div>
          </div>

          <div className="space-y-2">
            <Label>Versão do Sistema</Label>
            <Controller
                name="version"
                control={control}
                render={({ field }) => (
                  <Select onValueChange={field.onChange} defaultValue={field.value}>
                    <SelectTrigger>
                      <SelectValue placeholder="Ex: Nubo Hub, Nubo Conecta" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="Nubo Hub">Nubo Hub</SelectItem>
                      <SelectItem value="Nubo Conecta">Nubo Conecta</SelectItem>
                    </SelectContent>
                  </Select>
                )}
              />
            {errors.version && <p className="text-sm text-red-500">{errors.version.message}</p>}
          </div>

          <div className="space-y-2">
            <Label>Título Curto</Label>
            <Input {...register("title")} placeholder="Ex: Botão de salvar não responde" />
            {errors.title && <p className="text-sm text-red-500">{errors.title.message}</p>}
          </div>

          {issueType === "bug" && (
            <div className="space-y-4 animate-in fade-in slide-in-from-bottom-2">
              <div className="space-y-2">
                <Label>Comportamento Atual</Label>
                <Textarea {...register("actualBehavior")} placeholder="O que está acontecendo de errado?" />
                {errors.actualBehavior && <p className="text-sm text-red-500">{errors.actualBehavior.message}</p>}
              </div>
              <div className="space-y-2">
                <Label>Comportamento Esperado</Label>
                <Textarea {...register("expectedBehavior")} placeholder="O que deveria acontecer?" />
                {errors.expectedBehavior && <p className="text-sm text-red-500">{errors.expectedBehavior.message}</p>}
              </div>
              <div className="space-y-2">
                <Label>Passos para Reproduzir</Label>
                <Textarea {...register("stepsToReproduce")} placeholder="1. Clique em X\n2. Acesse Y\n3. Erro Z aparece" />
                {errors.stepsToReproduce && <p className="text-sm text-red-500">{errors.stepsToReproduce.message}</p>}
              </div>
              <div className="space-y-2">
                <Label>Severidade</Label>
                <Controller
                  name="severity"
                  control={control}
                  render={({ field }) => (
                    <Select onValueChange={field.onChange} defaultValue={field.value}>
                      <SelectTrigger>
                        <SelectValue placeholder="Selecione o impacto" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="baixa">Baixa (Visual, não bloqueante)</SelectItem>
                        <SelectItem value="media">Média (Atrapalha o fluxo mas tem contorno)</SelectItem>
                        <SelectItem value="alta">Alta (Bloqueia funcionalidades principais)</SelectItem>
                        <SelectItem value="critica">Crítica (Crash ou perda de dados)</SelectItem>
                      </SelectContent>
                    </Select>
                  )}
                />
                {errors.severity && <p className="text-sm text-red-500">{errors.severity.message}</p>}
              </div>
            </div>
          )}

          {issueType === "feature" && (
            <div className="space-y-4 animate-in fade-in slide-in-from-bottom-2">
              <div className="space-y-2">
                <Label>Problema ou Oportunidade</Label>
                <Textarea {...register("problemOpportunity")} placeholder="Qual problema do usuário estamos resolvendo?" />
                {errors.problemOpportunity && <p className="text-sm text-red-500">{errors.problemOpportunity.message}</p>}
              </div>
              <div className="space-y-2">
                <Label>Proposta de Solução</Label>
                <Textarea {...register("proposedSolution")} placeholder="Como você imagina que isso deveria funcionar?" />
                {errors.proposedSolution && <p className="text-sm text-red-500">{errors.proposedSolution.message}</p>}
              </div>
              <div className="space-y-2">
                <Label>Impacto Esperado</Label>
                <Textarea {...register("expectedImpact")} placeholder="O que ganhamos com isso? (Métricas, satisfação, etc)" />
                {errors.expectedImpact && <p className="text-sm text-red-500">{errors.expectedImpact.message}</p>}
              </div>
            </div>
          )}

          <div className="space-y-2">
            <Label>Anexo (Opcional - Print, Log, Video)</Label>
            <Input 
              type="file" 
              accept="image/*,video/*,.pdf"
              onChange={(e) => setAttachment(e.target.files ? e.target.files[0] : null)}
            />
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>Cancelar</Button>
            <Button type="submit" disabled={isPending}>
              {isPending ? "Aguarde..." : "Criar Issue no GitHub"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

import React, { useState } from "react";
import { useForm, Controller } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { createCard, uploadSupportAttachment } from "@/services/snapsApiService";
import { toast } from "sonner";
import { Paperclip, Loader2 } from "lucide-react";

const schema = z.object({
  title: z.string().min(5, "Mínimo 5 caracteres").max(100),
  environment: z.string().min(1, "Obrigatório"),
  steps_to_reproduce: z.string().min(1, "Obrigatório"),
  expected_behavior: z.string().min(1, "Obrigatório"),
  actual_behavior: z.string().min(1, "Obrigatório"),
  severity: z.enum(["low", "medium", "high", "critical"]),
});

type FormData = z.infer<typeof schema>;

interface Props {
  onSuccess?: () => void;
  onCancel?: () => void;
}

export function BugReportForm({ onSuccess, onCancel }: Props) {
  const [file, setFile] = useState<File | null>(null);
  const [isUploading, setIsUploading] = useState(false);

  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<FormData>({
    resolver: zodResolver(schema),
    defaultValues: { severity: "medium" },
  });

  const onSubmit = async (data: FormData) => {
    try {
      let attachmentMarkdown = "";
      
      if (file) {
        setIsUploading(true);
        try {
          const { url } = await uploadSupportAttachment(file);
          // If it's an image, use image markdown, else use link markdown
          const isImage = file.type.startsWith("image/");
          attachmentMarkdown = `\n\n**Anexos:**\n${isImage ? "!" : ""}[${file.name}](${url})`;
        } catch (uploadErr) {
          toast.error("Erro ao fazer upload do anexo. Enviando sem anexo.");
          console.error(uploadErr);
        } finally {
          setIsUploading(false);
        }
      }

      const finalDescription = data.actual_behavior + attachmentMarkdown;

      await createCard({
        card_type: "bug",
        title: data.title,
        description: finalDescription,
        metadata: {
          title: data.title,
          description: finalDescription,
          environment: data.environment,
          steps_to_reproduce: data.steps_to_reproduce,
          expected_behavior: data.expected_behavior,
          actual_behavior: finalDescription,
          severity: data.severity,
        },
      });
      toast.success("Bug reportado com sucesso no Snaps!");
      reset();
      setFile(null);
      onSuccess?.();
    } catch (err) {
      toast.error(`Erro: ${(err as Error).message}`);
    }
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      <div className="space-y-2">
        <Label>Título</Label>
        <Input {...register("title")} placeholder="Ex: Botão de salvar não responde" />
        {errors.title && <p className="text-sm text-red-500">{errors.title.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Ambiente</Label>
        <Input {...register("environment")} placeholder="Ex: Produção, Staging, Local" />
        {errors.environment && <p className="text-sm text-red-500">{errors.environment.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Comportamento Atual</Label>
        <Textarea {...register("actual_behavior")} placeholder="O que está acontecendo de errado?" />
        {errors.actual_behavior && <p className="text-sm text-red-500">{errors.actual_behavior.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Comportamento Esperado</Label>
        <Textarea {...register("expected_behavior")} placeholder="O que deveria acontecer?" />
        {errors.expected_behavior && <p className="text-sm text-red-500">{errors.expected_behavior.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Passos para Reproduzir</Label>
        <Textarea {...register("steps_to_reproduce")} placeholder={"1. Clique em X\n2. Acesse Y\n3. Erro Z aparece"} />
        {errors.steps_to_reproduce && <p className="text-sm text-red-500">{errors.steps_to_reproduce.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Severidade</Label>
        <Controller
          name="severity"
          control={control}
          render={({ field }) => (
            <Select onValueChange={field.onChange} value={field.value}>
              <SelectTrigger>
                <SelectValue placeholder="Selecione o impacto" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="low">Baixa (Visual, não bloqueante)</SelectItem>
                <SelectItem value="medium">Média (Atrapalha o fluxo mas tem contorno)</SelectItem>
                <SelectItem value="high">Alta (Bloqueia funcionalidades principais)</SelectItem>
                <SelectItem value="critical">Crítica (Crash ou perda de dados)</SelectItem>
              </SelectContent>
            </Select>
          )}
        />
        {errors.severity && <p className="text-sm text-red-500">{errors.severity.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Anexo</Label>
        <div className="flex items-center gap-2">
          <Input 
            type="file" 
            className="cursor-pointer file:cursor-pointer" 
            onChange={(e) => setFile(e.target.files?.[0] || null)}
          />
          {file && (
            <span className="text-sm text-muted-foreground flex items-center gap-1">
              <Paperclip className="w-4 h-4" />
              {file.name}
            </span>
          )}
        </div>
      </div>

      <div className="flex justify-end gap-2 pt-2">
        {onCancel && (
          <Button type="button" variant="outline" onClick={onCancel} disabled={isSubmitting || isUploading}>
            Cancelar
          </Button>
        )}
        <Button type="submit" disabled={isSubmitting || isUploading}>
          {isSubmitting || isUploading ? (
             <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Enviando...</>
          ) : "Reportar Bug"}
        </Button>
      </div>
    </form>
  );
}

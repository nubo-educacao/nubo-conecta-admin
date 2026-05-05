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
  pain_point: z.string().min(1, "Obrigatório"),
  description: z.string().min(1, "Obrigatório"),
  expected_impact: z.string().min(1, "Obrigatório"),
  priority: z.enum(["low", "medium", "high"]),
});

type FormData = z.infer<typeof schema>;

interface Props {
  onSuccess?: () => void;
  onCancel?: () => void;
}

export function FeatureRequestForm({ onSuccess, onCancel }: Props) {
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
    defaultValues: { priority: "medium" },
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

      const finalDescription = data.description + attachmentMarkdown;

      await createCard({
        card_type: "feature",
        title: data.title,
        description: finalDescription,
        metadata: {
          title: data.title,
          description: finalDescription,
          pain_point: data.pain_point,
          expected_impact: data.expected_impact,
          priority: data.priority,
        },
      });
      toast.success("Feature request enviada com sucesso no Snaps!");
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
        <Label>Título da Melhoria</Label>
        <Input {...register("title")} placeholder="Ex: Filtro avançado por curso" />
        {errors.title && <p className="text-sm text-red-500">{errors.title.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Problema ou Oportunidade</Label>
        <Textarea {...register("pain_point")} placeholder="Qual problema do usuário estamos resolvendo?" />
        {errors.pain_point && <p className="text-sm text-red-500">{errors.pain_point.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Proposta de Solução</Label>
        <Textarea {...register("description")} placeholder="Como você imagina que isso deveria funcionar?" />
        {errors.description && <p className="text-sm text-red-500">{errors.description.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Impacto Esperado</Label>
        <Textarea {...register("expected_impact")} placeholder="O que ganhamos com isso? (Métricas, satisfação, etc)" />
        {errors.expected_impact && <p className="text-sm text-red-500">{errors.expected_impact.message}</p>}
      </div>

      <div className="space-y-2">
        <Label>Prioridade</Label>
        <Controller
          name="priority"
          control={control}
          render={({ field }) => (
            <Select onValueChange={field.onChange} value={field.value}>
              <SelectTrigger>
                <SelectValue placeholder="Selecione a prioridade" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="low">Baixa</SelectItem>
                <SelectItem value="medium">Média</SelectItem>
                <SelectItem value="high">Alta</SelectItem>
              </SelectContent>
            </Select>
          )}
        />
        {errors.priority && <p className="text-sm text-red-500">{errors.priority.message}</p>}
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
          ) : "Enviar Sugestão"}
        </Button>
      </div>
    </form>
  );
}

// PartnerForm.tsx — Sprint 3.8
// V1 schema form for institutions + partner_institutions.
// Fields: name, description, location, brand_color, cover upload, logo upload.

import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import * as z from "zod";
import { Upload, X, Loader2, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
    Form,
    FormControl,
    FormField,
    FormItem,
    FormLabel,
    FormMessage,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Partner, uploadPartnerCover, uploadPartnerLogo } from "@/services/partnersService";
import { toast } from "sonner";

const partnerSchema = z.object({
    name: z.string().min(1, "Nome é obrigatório"),
    description: z.string().optional(),
    location: z.string().optional(),
    brand_color: z.string().optional(),
    cover_url: z.string().optional(),
    logo_url: z.string().optional(),
    website_url: z.string().url("URL inválida").optional().or(z.literal("")),
});

type PartnerFormValues = z.infer<typeof partnerSchema>;

interface PartnerFormProps {
    initialData?: Partner;
    onSubmit: (values: PartnerFormValues) => Promise<void>;
    onCancel: () => void;
    onDelete?: () => Promise<void>;
}

export function PartnerForm({ initialData, onSubmit, onCancel, onDelete }: PartnerFormProps) {
    const [isUploadingCover, setIsUploadingCover] = useState(false);
    const [isUploadingLogo, setIsUploadingLogo] = useState(false);
    const [previewCover, setPreviewCover] = useState<string | null>(initialData?.cover_url || null);
    const [previewLogo, setPreviewLogo] = useState<string | null>(initialData?.logo_url || null);

    const form = useForm<PartnerFormValues>({
        resolver: zodResolver(partnerSchema),
        defaultValues: {
            name: initialData?.name || "",
            description: initialData?.description || "",
            location: initialData?.location || "",
            brand_color: initialData?.brand_color || "",
            cover_url: initialData?.cover_url || "",
            logo_url: initialData?.logo_url || "",
            website_url: initialData?.website_url || "",
        },
    });

    const handleCoverUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (!file) return;
        try {
            setIsUploadingCover(true);
            const url = await uploadPartnerCover(file);
            form.setValue("cover_url", url);
            setPreviewCover(url);
            toast.success("Capa enviada com sucesso!");
        } catch (error) {
            toast.error("Erro ao enviar capa.");
            console.error(error);
        } finally {
            setIsUploadingCover(false);
        }
    };

    const handleLogoUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (!file) return;
        try {
            setIsUploadingLogo(true);
            const url = await uploadPartnerLogo(file);
            form.setValue("logo_url", url);
            setPreviewLogo(url);
            toast.success("Logo enviado com sucesso!");
        } catch (error) {
            toast.error("Erro ao enviar logo.");
            console.error(error);
        } finally {
            setIsUploadingLogo(false);
        }
    };

    const removeCover = () => { form.setValue("cover_url", ""); setPreviewCover(null); };
    const removeLogo  = () => { form.setValue("logo_url", ""); setPreviewLogo(null); };

    const handleSubmit = async (values: PartnerFormValues) => {
        await onSubmit(values);
    };

    return (
        <Form {...form}>
            <form onSubmit={form.handleSubmit(handleSubmit)} className="space-y-6">
                <div className="space-y-4">
                    <h3 className="text-lg font-medium">Dados do Parceiro</h3>

                    {/* Cover Image */}
                    <div className="space-y-2">
                        <FormLabel>Imagem de Capa</FormLabel>
                        <div className="flex flex-col items-center justify-center gap-4 rounded-lg border-2 border-dashed p-6 relative">
                            {previewCover ? (
                                <div className="relative aspect-video w-full max-w-[400px] overflow-hidden rounded-md">
                                    <img src={previewCover} alt="Capa" className="h-full w-full object-cover" />
                                    <Button
                                        type="button"
                                        variant="destructive"
                                        size="icon"
                                        className="absolute right-2 top-2 h-8 w-8"
                                        onClick={removeCover}
                                    >
                                        <X className="h-4 w-4" />
                                    </Button>
                                </div>
                            ) : (
                                <div className="flex flex-col items-center gap-2">
                                    <div className="rounded-full bg-muted p-3">
                                        {isUploadingCover ? (
                                            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                                        ) : (
                                            <Upload className="h-6 w-6 text-muted-foreground" />
                                        )}
                                    </div>
                                    <div className="text-center">
                                        <p className="text-sm font-medium">Clique para enviar a capa</p>
                                        <p className="text-xs text-muted-foreground">PNG, JPG ou WEBP (Max. 2MB)</p>
                                    </div>
                                    <input
                                        type="file"
                                        accept="image/*"
                                        className="absolute inset-0 cursor-pointer opacity-0"
                                        onChange={handleCoverUpload}
                                        disabled={isUploadingCover}
                                    />
                                </div>
                            )}
                        </div>
                    </div>

                    {/* Logo Image */}
                    <div className="space-y-2">
                        <FormLabel>Logo</FormLabel>
                        <div className="flex items-center gap-4">
                            {previewLogo ? (
                                <div className="relative h-16 w-16 overflow-hidden rounded-full border-2 border-border">
                                    <img src={previewLogo} alt="Logo" className="h-full w-full object-contain p-1" />
                                    <Button
                                        type="button"
                                        variant="destructive"
                                        size="icon"
                                        className="absolute -right-1 -top-1 h-5 w-5 rounded-full"
                                        onClick={removeLogo}
                                    >
                                        <X className="h-3 w-3" />
                                    </Button>
                                </div>
                            ) : (
                                <div className="relative flex h-16 w-16 items-center justify-center rounded-full border-2 border-dashed">
                                    {isUploadingLogo ? (
                                        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
                                    ) : (
                                        <Upload className="h-5 w-5 text-muted-foreground" />
                                    )}
                                    <input
                                        type="file"
                                        accept="image/*"
                                        className="absolute inset-0 cursor-pointer opacity-0"
                                        onChange={handleLogoUpload}
                                        disabled={isUploadingLogo}
                                    />
                                </div>
                            )}
                            <p className="text-xs text-muted-foreground">
                                Logo do parceiro (56×56px recomendado)
                            </p>
                        </div>
                    </div>

                    <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                        {/* Name */}
                        <FormField
                            control={form.control}
                            name="name"
                            render={({ field }) => (
                                <FormItem>
                                    <FormLabel>Nome</FormLabel>
                                    <FormControl>
                                        <Input placeholder="Nome do parceiro" {...field} />
                                    </FormControl>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />

                        {/* Location */}
                        <FormField
                            control={form.control}
                            name="location"
                            render={({ field }) => (
                                <FormItem>
                                    <FormLabel>Localização</FormLabel>
                                    <FormControl>
                                        <Input placeholder="Ex: Nacional, São Paulo" {...field} />
                                    </FormControl>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />
                    </div>

                    {/* Website URL */}
                    <FormField
                        control={form.control}
                        name="website_url"
                        render={({ field }) => (
                            <FormItem>
                                <FormLabel>Website</FormLabel>
                                <FormControl>
                                    <Input type="url" placeholder="https://exemplo.com.br" {...field} />
                                </FormControl>
                                <FormMessage />
                            </FormItem>
                        )}
                    />

                    {/* Description */}
                    <FormField
                        control={form.control}
                        name="description"
                        render={({ field }) => (
                            <FormItem>
                                <FormLabel>Descrição</FormLabel>
                                <FormControl>
                                    <Textarea placeholder="Breve descrição do parceiro..." {...field} />
                                </FormControl>
                                <FormMessage />
                            </FormItem>
                        )}
                    />

                    {/* Brand Color */}
                    <FormField
                        control={form.control}
                        name="brand_color"
                        render={({ field }) => (
                            <FormItem>
                                <FormLabel>Cor da Marca</FormLabel>
                                <div className="flex items-center gap-3">
                                    <FormControl>
                                        <Input
                                            type="color"
                                            className="h-10 w-14 cursor-pointer p-1"
                                            {...field}
                                        />
                                    </FormControl>
                                    <Input
                                        placeholder="#7030C2"
                                        value={field.value ?? ""}
                                        onChange={field.onChange}
                                        className="flex-1"
                                    />
                                </div>
                                <FormMessage />
                            </FormItem>
                        )}
                    />
                </div>

                <div className="flex justify-between items-center border-t pt-6">
                    <div>
                        {initialData && onDelete && (
                            <Button
                                type="button"
                                variant="destructive"
                                className="gap-2"
                                onClick={() => {
                                    if (confirm("Tem certeza que deseja remover este parceiro?")) {
                                        onDelete();
                                    }
                                }}
                            >
                                <Trash2 className="h-4 w-4" />
                                Remover Parceiro
                            </Button>
                        )}
                    </div>
                    <div className="flex gap-4">
                        <Button type="button" variant="outline" onClick={onCancel}>
                            Cancelar
                        </Button>
                        <Button type="submit" disabled={form.formState.isSubmitting}>
                            {form.formState.isSubmitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                            {initialData ? "Salvar Alterações" : "Cadastrar Parceiro"}
                        </Button>
                    </div>
                </div>
            </form>
        </Form>
    );
}

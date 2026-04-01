import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import * as z from "zod";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";
import { CalendarIcon, Upload, X, Loader2, Trash2 } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
    Form,
    FormControl,
    FormField,
    FormItem,
    FormLabel,
    FormMessage,
    FormDescription,
} from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
    Popover,
    PopoverContent,
    PopoverTrigger,
} from "@/components/ui/popover";
import { Calendar } from "@/components/ui/calendar";
import { Partner, uploadPartnerCover } from "@/services/partnersService";
import { toast } from "sonner";
import { Switch } from "@/components/ui/switch";

const partnerSchema = z.object({
    name: z.string().min(1, "Nome é obrigatório"),
    description: z.string().optional(),
    location: z.string().optional(),
    type: z.string().optional(),
    income: z.string().optional(),
    start_date: z.date({
        required_error: "Data de início é obrigatória",
    }),
    end_date: z.date().optional(),
    link: z.string().url("Link inválido").optional().or(z.literal("")),
    coverimage: z.string().optional(),
    applications_open: z.boolean().default(true),
    external_redirect_url: z.string().url("URL de redirecionamento inválida").optional().or(z.literal("")),
    external_redirect_title: z.string().optional(),
    external_redirect_message: z.string().optional(),
    external_redirect_button_text: z.string().optional(),
    external_redirect_type: z.enum(["whatsapp", "external"]).default("external"),
    has_external_redirect: z.boolean().default(false),
});

type PartnerFormValues = z.infer<typeof partnerSchema>;

interface PartnerFormProps {
    initialData?: Partner;
    onSubmit: (values: any) => Promise<void>;
    onCancel: () => void;
    onDelete?: () => Promise<void>;
}

export function PartnerForm({ initialData, onSubmit, onCancel, onDelete }: PartnerFormProps) {
    const [isUploading, setIsUploading] = useState(false);
    const [previewImage, setPreviewImage] = useState<string | null>(initialData?.coverimage || null);

    const form = useForm<PartnerFormValues>({
        resolver: zodResolver(partnerSchema),
        defaultValues: {
            name: initialData?.name || "",
            description: initialData?.description || "",
            location: initialData?.location || "",
            type: initialData?.type || "",
            income: initialData?.income || "",
            start_date: Array.isArray(initialData?.dates)
                ? (initialData.dates[0] as any)?.start_date ? new Date((initialData.dates[0] as any).start_date) : new Date()
                : (initialData?.dates as any)?.start_date ? new Date((initialData.dates as any).start_date) : new Date(),
            end_date: Array.isArray(initialData?.dates)
                ? (initialData.dates[0] as any)?.end_date ? new Date((initialData.dates[0] as any).end_date) : undefined
                : (initialData?.dates as any)?.end_date ? new Date((initialData.dates as any).end_date) : undefined,
            link: initialData?.link || "",
            coverimage: initialData?.coverimage || "",
            applications_open: initialData?.applications_open ?? true,
            external_redirect_url: initialData?.external_redirect_config?.url || "",
            external_redirect_title: initialData?.external_redirect_config?.title || "",
            external_redirect_message: initialData?.external_redirect_config?.message || "",
            external_redirect_button_text: initialData?.external_redirect_config?.buttonText || "",
            external_redirect_type: initialData?.external_redirect_config?.type || "external",
            has_external_redirect: !!initialData?.external_redirect_config,
        },
    });

    const handleImageUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (!file) return;

        try {
            setIsUploading(true);
            const url = await uploadPartnerCover(file);
            form.setValue("coverimage", url);
            setPreviewImage(url);
            toast.success("Imagem enviada com sucesso!");
        } catch (error) {
            toast.error("Erro ao enviar imagem.");
            console.error(error);
        } finally {
            setIsUploading(false);
        }
    };

    const removeImage = () => {
        form.setValue("coverimage", "");
        setPreviewImage(null);
    };

    const handleSubmit = async (values: PartnerFormValues) => {
        const formattedValues = {
            name: values.name,
            description: values.description,
            location: values.location,
            type: values.type,
            income: values.income,
            link: values.link,
            coverimage: values.coverimage,
            applications_open: values.applications_open,
            dates: [{
                start_date: values.start_date.toISOString().split("T")[0],
                end_date: values.end_date?.toISOString().split("T")[0],
            }],
            external_redirect_config: values.has_external_redirect && values.external_redirect_url ? {
                url: values.external_redirect_url,
                title: values.external_redirect_title,
                message: values.external_redirect_message,
                buttonText: values.external_redirect_button_text,
                type: values.external_redirect_type,
            } : null,
        };
        await onSubmit(formattedValues);
    };

    return (
        <Form {...form}>
            <form onSubmit={form.handleSubmit(handleSubmit)} className="space-y-6">
                <div className="space-y-4">
                    <h3 className="text-lg font-medium">Cadastro de informações</h3>

                    {/* Cover Image */}
                    <div className="space-y-2">
                        <FormLabel>Imagem de Capa</FormLabel>
                        <div className="flex flex-col items-center justify-center gap-4 rounded-lg border-2 border-dashed p-6">
                            {previewImage ? (
                                <div className="relative aspect-video w-full max-w-[300px] overflow-hidden rounded-md">
                                    <img src={previewImage} alt="Preview" className="h-full w-full object-cover" />
                                    <Button
                                        type="button"
                                        variant="destructive"
                                        size="icon"
                                        className="absolute right-2 top-2 h-8 w-8"
                                        onClick={removeImage}
                                    >
                                        <X className="h-4 w-4" />
                                    </Button>
                                </div>
                            ) : (
                                <div className="flex flex-col items-center gap-2">
                                    <div className="rounded-full bg-muted p-3">
                                        {isUploading ? (
                                            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                                        ) : (
                                            <Upload className="h-6 w-6 text-muted-foreground" />
                                        )}
                                    </div>
                                    <div className="text-center">
                                        <p className="text-sm font-medium">Clique para enviar ou arraste</p>
                                        <p className="text-xs text-muted-foreground">PNG, JPG ou WEBP (Max. 2MB)</p>
                                    </div>
                                    <input
                                        type="file"
                                        accept="image/*"
                                        className="absolute inset-0 cursor-pointer opacity-0"
                                        onChange={handleImageUpload}
                                        disabled={isUploading}
                                    />
                                </div>
                            )}
                        </div>
                    </div>

                    {/* Applications Open Switch */}
                    <FormField
                        control={form.control}
                        name="applications_open"
                        render={({ field }) => (
                            <FormItem className="flex flex-row items-center justify-between rounded-lg border p-4 bg-muted/20">
                                <div className="space-y-0.5">
                                    <FormLabel className="text-base text-primary">Inscrições Abertas?</FormLabel>
                                    <p className="text-sm text-muted-foreground">Define se o botão de Inscrição estará visível aos candidatos na plataforma.</p>
                                </div>
                                <FormControl>
                                    <Switch
                                        checked={field.value}
                                        onCheckedChange={field.onChange}
                                    />
                                </FormControl>
                            </FormItem>
                        )}
                    />

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

                        {/* Type */}
                        <FormField
                            control={form.control}
                            name="type"
                            render={({ field }) => (
                                <FormItem>
                                    <FormLabel>Tipo</FormLabel>
                                    <FormControl>
                                        <Input placeholder="Ex: Bolsas de Estudo" {...field} />
                                    </FormControl>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />
                    </div>

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

                    <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                        {/* Location */}
                        <FormField
                            control={form.control}
                            name="location"
                            render={({ field }) => (
                                <FormItem>
                                    <FormLabel>Localização</FormLabel>
                                    <FormControl>
                                        <Input placeholder="Ex: Nacional ou São Paulo, SP" {...field} />
                                    </FormControl>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />

                        {/* Income */}
                        <FormField
                            control={form.control}
                            name="income"
                            render={({ field }) => (
                                <FormItem>
                                    <FormLabel>Critério Socioeconômico</FormLabel>
                                    <FormControl>
                                        <Input placeholder="Ex: Até 1.5 salário mínimo" {...field} />
                                    </FormControl>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />
                    </div>

                    <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                        {/* Start Date */}
                        <FormField
                            control={form.control}
                            name="start_date"
                            render={({ field }) => (
                                <FormItem className="flex flex-col">
                                    <FormLabel>Data de Início</FormLabel>
                                    <Popover>
                                        <PopoverTrigger asChild>
                                            <FormControl>
                                                <Button
                                                    variant={"outline"}
                                                    className={cn(
                                                        "w-full pl-3 text-left font-normal",
                                                        !field.value && "text-muted-foreground"
                                                    )}
                                                >
                                                    {field.value ? (
                                                        format(field.value, "PPP", { locale: ptBR })
                                                    ) : (
                                                        <span>Selecione uma data</span>
                                                    )}
                                                    <CalendarIcon className="ml-auto h-4 w-4 opacity-50" />
                                                </Button>
                                            </FormControl>
                                        </PopoverTrigger>
                                        <PopoverContent className="w-auto p-0" align="start">
                                            <Calendar
                                                mode="single"
                                                selected={field.value}
                                                onSelect={field.onChange}
                                                disabled={(date) =>
                                                    date < new Date("1900-01-01")
                                                }
                                                initialFocus
                                            />
                                        </PopoverContent>
                                    </Popover>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />

                        {/* End Date */}
                        <FormField
                            control={form.control}
                            name="end_date"
                            render={({ field }) => (
                                <FormItem className="flex flex-col">
                                    <FormLabel>Data de Fim</FormLabel>
                                    <Popover>
                                        <PopoverTrigger asChild>
                                            <FormControl>
                                                <Button
                                                    variant={"outline"}
                                                    className={cn(
                                                        "w-full pl-3 text-left font-normal",
                                                        !field.value && "text-muted-foreground"
                                                    )}
                                                >
                                                    {field.value ? (
                                                        format(field.value, "PPP", { locale: ptBR })
                                                    ) : (
                                                        <span>Selecione uma data</span>
                                                    )}
                                                    <CalendarIcon className="ml-auto h-4 w-4 opacity-50" />
                                                </Button>
                                            </FormControl>
                                        </PopoverTrigger>
                                        <PopoverContent className="w-auto p-0" align="start">
                                            <Calendar
                                                mode="single"
                                                selected={field.value}
                                                onSelect={field.onChange}
                                                disabled={(date) =>
                                                    date < new Date("1900-01-01")
                                                }
                                                initialFocus
                                            />
                                        </PopoverContent>
                                    </Popover>
                                    <FormMessage />
                                </FormItem>
                            )}
                        />
                    </div>

                    {/* Link */}
                    <FormField
                        control={form.control}
                        name="link"
                        render={({ field }) => (
                            <FormItem>
                                <FormLabel>Link</FormLabel>
                                <FormControl>
                                    <Input placeholder="https://exemplo.com" {...field} />
                                </FormControl>
                                <FormMessage />
                            </FormItem>
                        )}
                    />

                    <div className="pt-4 border-t space-y-4">
                        <div className="flex flex-row items-center justify-between rounded-lg border p-4 bg-blue-50/30">
                            <div className="space-y-0.5">
                                <FormLabel className="text-base text-blue-600 font-semibold">Redirecionamento Externo (Modal)</FormLabel>
                                <FormDescription className="text-xs">
                                    Ative se a inscrição ocorrer fora da Cloudinha (Ex: WhatsApp ou Site do Parceiro).
                                </FormDescription>
                            </div>
                            <FormField
                                control={form.control}
                                name="has_external_redirect"
                                render={({ field }) => (
                                    <FormItem>
                                        <FormControl>
                                            <Switch
                                                checked={field.value}
                                                onCheckedChange={field.onChange}
                                            />
                                        </FormControl>
                                    </FormItem>
                                )}
                            />
                        </div>

                        {form.watch("has_external_redirect") && (
                            <div className="space-y-4 animate-in fade-in slide-in-from-top-2 duration-300">
                                <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                                    <FormField
                                        control={form.control}
                                        name="external_redirect_url"
                                        render={({ field }) => (
                                            <FormItem>
                                                <FormLabel>URL de Redirecionamento</FormLabel>
                                                <FormControl>
                                                    <Input placeholder="https://..." {...field} />
                                                </FormControl>
                                                <FormDescription className="text-xs">Ex: Link do WhatsApp ou Site Externo</FormDescription>
                                                <FormMessage />
                                            </FormItem>
                                        )}
                                    />

                                    <FormField
                                        control={form.control}
                                        name="external_redirect_type"
                                        render={({ field }) => (
                                            <FormItem>
                                                <FormLabel>Tipo de Redirecionamento</FormLabel>
                                                <FormControl>
                                                    <select 
                                                        className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
                                                        {...field}
                                                    >
                                                        <option value="external">Link Externo (Padrão)</option>
                                                        <option value="whatsapp">WhatsApp (Verde)</option>
                                                    </select>
                                                </FormControl>
                                                <FormMessage />
                                            </FormItem>
                                        )}
                                    />
                                </div>

                                <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                                    <FormField
                                        control={form.control}
                                        name="external_redirect_title"
                                        render={({ field }) => (
                                            <FormItem>
                                                <FormLabel>Título da Modal</FormLabel>
                                                <FormControl>
                                                    <Input placeholder="Ex: Processo Seletivo" {...field} />
                                                </FormControl>
                                                <FormMessage />
                                            </FormItem>
                                        )}
                                    />

                                    <FormField
                                        control={form.control}
                                        name="external_redirect_button_text"
                                        render={({ field }) => (
                                            <FormItem>
                                                <FormLabel>Texto do Botão</FormLabel>
                                                <FormControl>
                                                    <Input placeholder="Ex: Ir para o WhatsApp" {...field} />
                                                </FormControl>
                                                <FormMessage />
                                            </FormItem>
                                        )}
                                    />
                                </div>

                                <FormField
                                    control={form.control}
                                    name="external_redirect_message"
                                    render={({ field }) => (
                                        <FormItem>
                                            <FormLabel>Mensagem da Modal</FormLabel>
                                            <FormControl>
                                                <Textarea placeholder="A inscrição não é realizada diretamente pela Cloudinha..." {...field} />
                                            </FormControl>
                                            <FormMessage />
                                        </FormItem>
                                    )}
                                />
                            </div>
                        )}
                    </div>
                </div>

                <div className="flex justify-between items-center border-t pt-6">
                    <div>
                        {initialData && onDelete && (
                            <Button
                                type="button"
                                variant="destructive"
                                className="gap-2"
                                onClick={() => {
                                    if (confirm("Tem certeza que deseja apagar este parceiro?")) {
                                        onDelete();
                                    }
                                }}
                            >
                                <Trash2 className="h-4 w-4" />
                                Apagar Parceiro
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

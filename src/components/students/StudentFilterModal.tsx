import { useState, useEffect } from "react";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { StudentFilters } from "@/services/studentsService";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { Checkbox } from "@/components/ui/checkbox";
import { ScrollArea } from "@/components/ui/scroll-area";
import { QUOTA_OPTIONS } from "@/constants/quotaOptions";
import { getStates, getCities, State, City } from "@/services/locationService";
import {
    Command,
    CommandEmpty,
    CommandGroup,
    CommandInput,
    CommandItem,
    CommandList,
} from "@/components/ui/command";
import {
    Popover,
    PopoverContent,
    PopoverTrigger,
} from "@/components/ui/popover";
import { Check, ChevronsUpDown, Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";

interface StudentFilterModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    filters: StudentFilters;
    onApplyFilters: (newFilters: StudentFilters) => void;
    onClearFilters: () => void;
}

const EDUCATION_OPTIONS = [
    { label: "Ensino Médio Completo", value: "Ensino M%dio Completo" },
    { label: "Ensino Médio Incompleto", value: "Ensino M%dio Incompleto" },
    { label: "Ensino Superior Completo", value: "Ensino Superior Completo" },
    { label: "Ensino Superior Incompleto", value: "Ensino Superior Incompleto" }
];

export function StudentFilterModal({
    open,
    onOpenChange,
    filters,
    onApplyFilters,
    onClearFilters,
}: StudentFilterModalProps) {
    const [localFilters, setLocalFilters] = useState<StudentFilters>(filters);
    const [states, setStates] = useState<State[]>([]);
    const [cities, setCities] = useState<City[]>([]);
    const [loadingStates, setLoadingStates] = useState(false);
    const [loadingCities, setLoadingCities] = useState(false);

    // City Combobox state
    const [cityOpen, setCityOpen] = useState(false);
    const [citySearch, setCitySearch] = useState("");

    useEffect(() => {
        setLocalFilters(filters);
    }, [filters, open]);

    useEffect(() => {
        const loadStates = async () => {
            setLoadingStates(true);
            try {
                const data = await getStates();
                setStates(data);
            } catch (error) {
                console.error("Failed to load states", error);
            } finally {
                setLoadingStates(false);
            }
        };
        loadStates();
    }, []);

    useEffect(() => {
        const loadCities = async () => {
            if (!citySearch && !localFilters.state) {
                setCities([]);
                return;
            }

            setLoadingCities(true);
            try {
                // Determine state filter for city query
                // If a state is selected in filters, use it.
                const stateFilter = localFilters.state || "";

                // Only fetch if we have a search term OR a state selected
                if (stateFilter || citySearch.length > 2) {
                    const data = await getCities(stateFilter, citySearch);
                    setCities(data);
                } else {
                    setCities([]);
                }
            } catch (error) {
                console.error("Failed to load cities", error);
            } finally {
                setLoadingCities(false);
            }
        };

        // Debounce search
        const timeoutId = setTimeout(loadCities, 300);
        return () => clearTimeout(timeoutId);
    }, [citySearch, localFilters.state]);

    const handleApply = () => {
        onApplyFilters(localFilters);
        onOpenChange(false);
    };

    const handleClear = () => {
        onClearFilters();
        setLocalFilters({});
        setCitySearch("");
        onOpenChange(false);
    };

    const toggleQuota = (id: string) => {
        setLocalFilters(prev => {
            const current = prev.quotaTypes || [];
            if (current.includes(id)) {
                return { ...prev, quotaTypes: current.filter(x => x !== id) };
            } else {
                return { ...prev, quotaTypes: [...current, id] };
            }
        });
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="sm:max-w-[700px] max-h-[90vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle>Filtrar Estudantes</DialogTitle>
                </DialogHeader>
                <div className="grid grid-cols-2 gap-4 py-4">
                    {/* Nome */}
                    <div className="col-span-2 grid gap-2">
                        <Label htmlFor="fullName">Nome Completo</Label>
                        <Input
                            id="fullName"
                            placeholder="Buscar por nome..."
                            value={localFilters.fullName || ""}
                            onChange={(e) =>
                                setLocalFilters({ ...localFilters, fullName: e.target.value })
                            }
                        />
                    </div>

                    {/* Estado */}
                    <div className="grid gap-2">
                        <div className="flex items-center justify-between">
                            <Label htmlFor="state">Estado</Label>
                            {localFilters.state && (
                                <button
                                    onClick={() => {
                                        setLocalFilters({ ...localFilters, state: undefined, city: undefined });
                                        setCitySearch("");
                                    }}
                                    className="text-xs text-muted-foreground hover:text-foreground"
                                >
                                    Limpar
                                </button>
                            )}
                        </div>
                        <Select
                            value={localFilters.state || "all"}
                            onValueChange={(value) => {
                                const newState = value === "all" ? undefined : value;
                                setLocalFilters({ ...localFilters, state: newState, city: undefined }); // Clear city when state changes
                                setCitySearch(""); // Reset city search
                            }}
                        >
                            <SelectTrigger id="state">
                                <SelectValue placeholder="Selecione o estado" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="all">Todos os estados</SelectItem>
                                {states.map((state) => (
                                    <SelectItem key={state.uf} value={state.uf}>
                                        {state.name} ({state.uf})
                                    </SelectItem>
                                ))}
                            </SelectContent>
                        </Select>
                    </div>

                    {/* Cidade (Autocomplete) */}
                    <div className="grid gap-2">
                        <div className="flex items-center justify-between">
                            <Label htmlFor="city">Cidade</Label>
                            {localFilters.city && (
                                <button
                                    onClick={() => {
                                        setLocalFilters({ ...localFilters, city: undefined });
                                        setCitySearch("");
                                    }}
                                    className="text-xs text-muted-foreground hover:text-foreground"
                                >
                                    Limpar
                                </button>
                            )}
                        </div>
                        <Popover open={cityOpen} onOpenChange={setCityOpen}>
                            <PopoverTrigger asChild>
                                <Button
                                    variant="outline"
                                    role="combobox"
                                    aria-expanded={cityOpen}
                                    className="justify-between w-full"
                                >
                                    {localFilters.city
                                        ? localFilters.city
                                        : "Selecione a cidade..."}
                                    <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
                                </Button>
                            </PopoverTrigger>
                            <PopoverContent className="w-[--radix-popover-trigger-width] p-0">
                                <Command shouldFilter={false}>
                                    <CommandInput
                                        placeholder="Buscar cidade..."
                                        value={citySearch}
                                        onValueChange={setCitySearch}
                                    />
                                    <CommandList>
                                        <CommandEmpty>
                                            {loadingCities ? (
                                                <div className="flex items-center justify-center p-2">
                                                    <Loader2 className="h-4 w-4 animate-spin mr-2" />
                                                    Carregando...
                                                </div>
                                            ) : (
                                                "Nenhuma cidade encontrada."
                                            )}
                                        </CommandEmpty>
                                        <CommandGroup>
                                            {cities.map((city) => (
                                                <CommandItem
                                                    key={city.id}
                                                    value={city.name}
                                                    onSelect={(currentValue) => {
                                                        setLocalFilters({ ...localFilters, city: currentValue });
                                                        setCityOpen(false);
                                                    }}
                                                >
                                                    <Check
                                                        className={cn(
                                                            "mr-2 h-4 w-4",
                                                            localFilters.city === city.name ? "opacity-100" : "opacity-0"
                                                        )}
                                                    />
                                                    {city.name} - {city.state}
                                                </CommandItem>
                                            ))}
                                        </CommandGroup>
                                    </CommandList>
                                </Command>
                            </PopoverContent>
                        </Popover>
                    </div>

                    {/* Escolaridade (Select) */}
                    <div className="grid gap-2">
                        <Label htmlFor="education">Escolaridade</Label>
                        <Select
                            value={localFilters.education || "all"}
                            onValueChange={(value) => {
                                setLocalFilters({ ...localFilters, education: value === "all" ? undefined : value });
                            }}
                        >
                            <SelectTrigger id="education">
                                <SelectValue placeholder="Selecione a escolaridade" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="all">Todas</SelectItem>
                                {EDUCATION_OPTIONS.map((edu) => (
                                    <SelectItem key={edu.value} value={edu.value}>
                                        {edu.label}
                                    </SelectItem>
                                ))}
                            </SelectContent>
                        </Select>
                    </div>

                    {/* Estudante Nubo */}
                    <div className="grid gap-2">
                        <Label htmlFor="isNuboStudent">Estudante Nubo</Label>
                        <Select
                            value={localFilters.isNuboStudent === true ? "true" : localFilters.isNuboStudent === false ? "false" : "all"}
                            onValueChange={(value) => {
                                let newValue: boolean | null | undefined = undefined;
                                if (value === "true") newValue = true;
                                if (value === "false") newValue = false;
                                setLocalFilters({ ...localFilters, isNuboStudent: newValue });
                            }}
                        >
                            <SelectTrigger id="isNuboStudent">
                                <SelectValue placeholder="Selecione" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="all">Ambos</SelectItem>
                                <SelectItem value="true">Sim</SelectItem>
                                <SelectItem value="false">Não</SelectItem>
                            </SelectContent>
                        </Select>
                    </div>

                    {/* Idade Filters */}
                    <div className="col-span-2 grid gap-2">
                        <Label>Idade</Label>
                        <div className="flex gap-4 items-center">
                            <div className="flex-1">
                                <Input
                                    type="number"
                                    placeholder="Idade Mínima"
                                    value={localFilters.ageMin || ""}
                                    onChange={(e) =>
                                        setLocalFilters({ ...localFilters, ageMin: e.target.value ? Number(e.target.value) : undefined })
                                    }
                                />
                            </div>
                            <span>até</span>
                            <div className="flex-1">
                                <Input
                                    type="number"
                                    placeholder="Idade Máxima"
                                    value={localFilters.ageMax || ""}
                                    onChange={(e) =>
                                        setLocalFilters({ ...localFilters, ageMax: e.target.value ? Number(e.target.value) : undefined })
                                    }
                                />
                            </div>
                        </div>
                    </div>

                    {/* Renda Filter - Full Width */}
                    <div className="col-span-2 grid gap-2">
                        <Label>Renda Familiar Per Capita (R$)</Label>
                        <div className="flex gap-4 items-center">
                            <div className="flex-1">
                                <Input
                                    type="number"
                                    placeholder="Mínimo"
                                    value={localFilters.incomeMin || ""}
                                    onChange={(e) =>
                                        setLocalFilters({ ...localFilters, incomeMin: e.target.value ? Number(e.target.value) : undefined })
                                    }
                                />
                            </div>
                            <span>até</span>
                            <div className="flex-1">
                                <Input
                                    type="number"
                                    placeholder="Máximo"
                                    value={localFilters.incomeMax || ""}
                                    onChange={(e) =>
                                        setLocalFilters({ ...localFilters, incomeMax: e.target.value ? Number(e.target.value) : undefined })
                                    }
                                />
                            </div>
                        </div>
                    </div>

                    {/* Quota Filter - Full Width */}
                    <div className="col-span-2 grid gap-2">
                        <Label>Cotas (Selecione para filtrar quem possui)</Label>
                        <ScrollArea className="h-[200px] w-full rounded-md border p-4">
                            <div className="grid grid-cols-2 gap-2">
                                {QUOTA_OPTIONS.map((quota) => (
                                    <div key={quota.id} className="flex items-start space-x-2">
                                        <Checkbox
                                            id={quota.id}
                                            checked={(localFilters.quotaTypes || []).includes(quota.id)}
                                            onCheckedChange={() => toggleQuota(quota.id)}
                                        />
                                        <label
                                            htmlFor={quota.id}
                                            className="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70 cursor-pointer"
                                        >
                                            {quota.label}
                                        </label>
                                    </div>
                                ))}
                            </div>
                        </ScrollArea>
                    </div>
                </div>
                <DialogFooter>
                    <Button variant="outline" onClick={handleClear}>
                        Limpar Filtros
                    </Button>
                    <Button onClick={handleApply}>Aplicar Filtros</Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}

// ─── Shared Form Constants ──────────────────────────────────────────────────
// Extracted from PartnerFormsManager for reuse across the Partner Portal.

export const DATA_TYPES = [
    { value: "text", label: "Texto" },
    { value: "number", label: "Número" },
    { value: "boolean", label: "Sim/Não" },
    { value: "select", label: "Seleção" },
    { value: "searchable_select", label: "Seleção com Busca (Autocomplete)" },
    { value: "multiselect", label: "Multiseleção" },
    { value: "grid_select", label: "Grade de Seleção" },
    { value: "grid_multiselect", label: "Grade de Múltipla Escolha" },
];

export const MAPPING_LABELS: Record<string, string> = {
    "user_profiles.full_name": "Perfil: Nome Completo",
    "user_profiles.age": "Perfil: Idade",
    "user_profiles.city": "Perfil: Cidade",
    "user_profiles.state": "Perfil: Estado",
    "user_profiles.education": "Perfil: Escolaridade",
    "user_profiles.education_year": "Perfil: Ano Escolar",
    "user_profiles.zip_code": "Perfil: CEP",
    "user_profiles.street": "Perfil: Rua",
    "user_profiles.street_number": "Perfil: Número",
    "user_profiles.complement": "Perfil: Complemento",
    "user_profiles.phone": "Perfil: Telefone",
    "user_profiles.relationship": "Perfil: Parentesco",
    "user_profiles.is_nubo_student": "Perfil: É Aluno Nubo",
    "user_profiles.referral_source": "Perfil: Como conheceu",
    "user_profiles.neighborhood": "Perfil: Bairro",
    "user_profiles.country": "Perfil: País",
    "user_profiles.birth_date": "Perfil: Data de Nascimento",
    "user_preferences.enem_score": "Prefs: Nota ENEM",
    "user_preferences.family_income_per_capita": "Prefs: Renda Per Capita",
    "user_preferences.course_interest": "Prefs: Interesse em Cursos",
    "user_preferences.location_preference": "Prefs: Preferência de Local",
    "user_preferences.preferred_shifts": "Prefs: Turnos Preferidos",
    "user_preferences.program_preference": "Prefs: Preferência de Programa",
    "user_preferences.quota_types": "Prefs: Tipos de Cota",
    "user_preferences.state_preference": "Prefs: Estado de Preferência",
    "user_preferences.university_preference": "Prefs: Universidade de Preferência",
    "user_income.per_capita_income": "Renda: Per Capita",
    "user_income.family_count": "Renda: Qtd Familiares",
    "user_enem_scores.average_score": "ENEM: Média Geral",
    "auth.users.phone": "Usuário: Telefone",
    "auth.users.email": "Usuário: E-mail",
};

export const getMappingLabel = (value: string): string => {
    if (MAPPING_LABELS[value]) return MAPPING_LABELS[value];

    const parts = value.split(".");
    if (parts.length < 2) return value;

    const table = parts.length === 3 ? parts[1] : parts[0];
    const column = parts.length === 3 ? parts[2] : parts[1];

    const prefixMap: Record<string, string> = {
        'user_profiles': 'Perfil',
        'user_preferences': 'Prefs',
        'user_income': 'Renda',
        'user_enem_scores': 'ENEM',
        'users': 'Usuário'
    };

    const prefix = prefixMap[table] || table;
    const name = column.replace(/_/g, ' ')
                      .split(' ')
                      .map(w => w.charAt(0).toUpperCase() + w.slice(1))
                      .join(' ');

    return `${prefix}: ${name}`;
};

export const MASK_TYPES_TEXT = [
    { value: "none", label: "Nenhuma" },
    { value: "email", label: "E-mail" },
    { value: "link", label: "Link/URL" },
    { value: "textarea", label: "Texto Longo (Textarea)" },
];

export const MASK_TYPES_NUMBER = [
    { value: "none", label: "Nenhuma" },
    { value: "cpf", label: "CPF" },
    { value: "cnpj", label: "CNPJ" },
    { value: "phone", label: "Telefone" },
    { value: "cep", label: "CEP" },
    { value: "brl", label: "Moeda (BRL)" },
    { value: "date", label: "Data" },
];

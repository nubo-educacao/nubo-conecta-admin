import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { StudentTable } from "@/components/students/StudentTable";
import {
    getStudents,
    SORTABLE_STUDENT_FIELDS,
    type StudentProfile,
} from "@/services/studentsService";
import { supabase } from "@/integrations/supabase/client";

vi.mock("@/integrations/supabase/client", () => ({
    supabase: { rpc: vi.fn() },
}));

const rpc = vi.mocked(supabase.rpc);

const students: StudentProfile[] = [
    {
        id: "aaaaaaaa-0000-0000-0000-000000000001",
        full_name: "Ana",
        age: 22,
        city: "Sao Paulo",
        education: "superior",
        state: "SP",
        is_nubo_student: true,
        created_at: "2026-01-01T00:00:00Z",
    },
];

beforeEach(() => {
    rpc.mockReset();
    rpc.mockResolvedValue({ data: { data: [], count: 0 }, error: null } as never);
});

describe("contrato de ordenação de Estudantes (card 1a658f84)", () => {
    it("toda coluna clicável da tabela existe na whitelist da RPC", () => {
        const onSort = vi.fn();
        const { container } = render(
            <StudentTable students={students} onViewDetails={vi.fn()} onSort={onSort} />
        );

        const clickableHeaders = container.querySelectorAll("th.cursor-pointer");
        clickableHeaders.forEach((th) => fireEvent.click(th));

        const emitted = onSort.mock.calls.map(([field]) => field).sort();
        const allowed = [...SORTABLE_STUDENT_FIELDS].sort();

        // Se este teste falhar, alguém tornou uma coluna ordenável na UI sem
        // adicioná-la ao CASE da RPC. O sintoma em produção é silencioso: a
        // ordenação simplesmente não acontece.
        expect(emitted).toEqual(allowed);
    });

    it("cobre age e whatsapp, as duas colunas que a RPC não mapeava", () => {
        // Regressão direta do bug: ambas eram clicáveis e caíam no ELSE.
        expect(SORTABLE_STUDENT_FIELDS).toContain("age");
        expect(SORTABLE_STUDENT_FIELDS).toContain("whatsapp");
    });

    it("encaminha sortBy e sortOrder para a RPC", async () => {
        await getStudents({ page: 0, pageSize: 20, sortBy: "age", sortOrder: "asc" });

        expect(rpc).toHaveBeenCalledWith(
            "get_students_paginated",
            expect.objectContaining({ p_sort_by: "age", p_sort_order: "asc" })
        );
    });

    it("usa created_at desc como padrão quando o sort não é informado", async () => {
        await getStudents({});

        expect(rpc).toHaveBeenCalledWith(
            "get_students_paginated",
            expect.objectContaining({ p_sort_by: "created_at", p_sort_order: "desc" })
        );
    });

    it("propaga o erro de autorização da RPC em vez de engolir", async () => {
        // A RPC agora tem guard is_backoffice_admin(); um usuário sem permissão
        // recebe 42501. A tela precisa enxergar o erro, não uma lista vazia.
        rpc.mockResolvedValue({
            data: null,
            error: { code: "42501", message: "acesso restrito ao backoffice" },
        } as never);

        await expect(getStudents({})).rejects.toMatchObject({ code: "42501" });
    });
});

describe("StudentTable", () => {
    it("renderiza o estudante recebido", () => {
        render(<StudentTable students={students} onViewDetails={vi.fn()} onSort={vi.fn()} />);
        expect(screen.getByText("Ana")).toBeInTheDocument();
    });
});

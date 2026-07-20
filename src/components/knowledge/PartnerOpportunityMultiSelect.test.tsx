import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import PartnerOpportunityMultiSelect from "./PartnerOpportunityMultiSelect";

const OPTIONS = [
  { id: "752414b5-2356-4c88-affd-829f00abbbfa", name: "Bolsa Integral do Insper" },
  { id: "26625dc2-5dec-4e8f-8eef-8d570c2d0f98", name: "Bolsa Parcial do Insper" },
  { id: "8cb2f939-1875-497e-a43a-83371ae4f0c2", name: "BIP Impulsiona" },
];

describe("PartnerOpportunityMultiSelect", () => {
  it("mostra 'Nenhuma selecionada' quando selectedIds está vazio", () => {
    render(
      <PartnerOpportunityMultiSelect options={OPTIONS} selectedIds={[]} onChange={vi.fn()} />
    );
    expect(screen.getByText("Nenhuma selecionada")).toBeInTheDocument();
  });

  it("lista todas as opções com checkbox marcado para as já selecionadas", () => {
    render(
      <PartnerOpportunityMultiSelect
        options={OPTIONS}
        selectedIds={[OPTIONS[0].id]}
        onChange={vi.fn()}
      />
    );
    expect(screen.getByRole("checkbox", { name: OPTIONS[0].name })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: OPTIONS[1].name })).not.toBeChecked();
  });

  it("chama onChange adicionando o id ao marcar uma opção não selecionada", () => {
    const onChange = vi.fn();
    render(
      <PartnerOpportunityMultiSelect
        options={OPTIONS}
        selectedIds={[OPTIONS[0].id]}
        onChange={onChange}
      />
    );

    fireEvent.click(screen.getByRole("checkbox", { name: OPTIONS[1].name }));

    expect(onChange).toHaveBeenCalledWith([OPTIONS[0].id, OPTIONS[1].id]);
  });

  it("chama onChange removendo o id ao desmarcar uma opção selecionada", () => {
    const onChange = vi.fn();
    render(
      <PartnerOpportunityMultiSelect
        options={OPTIONS}
        selectedIds={[OPTIONS[0].id, OPTIONS[1].id]}
        onChange={onChange}
      />
    );

    fireEvent.click(screen.getByRole("checkbox", { name: OPTIONS[0].name }));

    expect(onChange).toHaveBeenCalledWith([OPTIONS[1].id]);
  });

  it("permite remover uma seleção pelo badge, sem precisar achar o checkbox", () => {
    const onChange = vi.fn();
    render(
      <PartnerOpportunityMultiSelect
        options={OPTIONS}
        selectedIds={[OPTIONS[0].id, OPTIONS[1].id]}
        onChange={onChange}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: `Remover ${OPTIONS[0].name}` }));

    expect(onChange).toHaveBeenCalledWith([OPTIONS[1].id]);
  });
});

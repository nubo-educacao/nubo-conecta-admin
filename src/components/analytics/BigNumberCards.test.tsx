// Big numbers do Command Center: tooltips inteiros (portal) e Power Users alinhado ao topo.
import { describe, expect, it } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { MessageSquare } from "lucide-react";
import { StatCard } from "./StatCard";
import { PowerUsersCard } from "./PowerUsersCard";
import { TotalUsersCard } from "./TotalUsersCard";

const MSG_TIP = "Mensagens enviadas por usuários no período selecionado.";

describe("tooltips dos big numbers", () => {
  it("abre por clique/toque e renderiza fora do card (portal), sem recorte do overflow-hidden", () => {
    const { container } = render(<StatCard title="Total de Mensagens" value="10" icon={MessageSquare} tooltip={MSG_TIP} />);
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Sobre Total de Mensagens" }));
    const tip = screen.getByRole("tooltip");
    expect(tip).toHaveTextContent(MSG_TIP);
    expect(container.contains(tip)).toBe(false);
    // Toque = foco + clique: o segundo evento não pode fechar o que o primeiro abriu.
    fireEvent.click(screen.getByRole("button", { name: "Sobre Total de Mensagens" }));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.keyDown(document.activeElement ?? document.body, { key: "Escape" });
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("Usuários Cadastrados também usa o portal", () => {
    const { container } = render(<TotalUsersCard totalRegistered={5000} activeUsers={10} activeWithMessages={5} catalogUsers={5} />);
    fireEvent.click(screen.getByRole("button", { name: "Sobre Usuários Cadastrados" }));
    const tip = screen.getByRole("tooltip");
    expect(tip).toHaveTextContent(/auth\.users/);
    expect(container.contains(tip)).toBe(false);
  });
});

describe("Power Users", () => {
  const user = { userId: "u1", userName: "Ana", userPhone: "", accessCount: 3 };

  it("conteúdo alinhado ao topo (button centraliza por padrão) e mantém o chevron de drill-down", () => {
    const { container } = render(<PowerUsersCard count={7} powerUsersList={[user]} />);
    const card = screen.getByRole("button", { name: /^Power Users/ });
    expect(card).toHaveClass("flex", "flex-col", "justify-start");
    expect(card).toHaveTextContent("7");
    expect(container.querySelector(".lucide-chevron-right")).toBeInTheDocument();
  });

  it("o ícone ? abre o tooltip sem abrir a lista; o card abre a lista", () => {
    const { container } = render(<PowerUsersCard count={7} powerUsersList={[user]} />);
    fireEvent.click(screen.getByRole("button", { name: "Sobre Power Users" }));
    const tip = screen.getByRole("tooltip");
    expect(tip).toHaveTextContent(/2 ou mais sessões/);
    expect(container.contains(tip)).toBe(false);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^Power Users/ }));
    expect(screen.getByRole("dialog")).toHaveTextContent("Ana");
  });
});

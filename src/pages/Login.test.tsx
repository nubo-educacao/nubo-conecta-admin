// TP-C / NUB-RD-95 — nova tela de login (identidade Nubo, PT-BR, a11y).
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { supabase } from "@/integrations/supabase/client";
import { loginErrorMessage } from "@/lib/loginErrors";
import Login from "./Login";

const { navigate, toastSuccess } = vi.hoisted(() => ({ navigate: vi.fn(), toastSuccess: vi.fn() }));
vi.mock("react-router-dom", async (orig) => ({ ...(await orig<typeof import("react-router-dom")>()), useNavigate: () => navigate }));
vi.mock("sonner", () => ({ toast: { success: toastSuccess, error: vi.fn() } }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { auth: { signInWithPassword: vi.fn() } } }));

const signIn = vi.mocked(supabase.auth.signInWithPassword);

beforeEach(() => {
  navigate.mockReset();
  toastSuccess.mockReset();
  signIn.mockReset();
});
afterEach(cleanup);

const renderLogin = () => render(<MemoryRouter><Login /></MemoryRouter>);

function fill(email = "ana@nubo.com", password = "segredo123") {
  fireEvent.change(screen.getByLabelText("E-mail"), { target: { value: email } });
  fireEvent.change(screen.getByLabelText("Senha"), { target: { value: password } });
}

const submit = () => fireEvent.click(screen.getByRole("button", { name: /Entrar|Entrando/ }));

describe("Login · estrutura e acessibilidade", () => {
  it("tem título, logo Nubo e campos rotulados com autocomplete correto", () => {
    renderLogin();
    expect(screen.getByRole("heading", { level: 1, name: "Nubo Conecta Admin" })).toBeInTheDocument();
    expect(screen.getByAltText("Nubo Conecta")).toHaveAttribute("src", expect.stringMatching(/^\/brand\/nubo-logo/));

    const email = screen.getByLabelText("E-mail");
    expect(email).toHaveAttribute("type", "email");
    expect(email).toHaveAttribute("autocomplete", "email");
    expect(email).toBeRequired();

    const password = screen.getByLabelText("Senha");
    expect(password).toHaveAttribute("type", "password");
    expect(password).toHaveAttribute("autocomplete", "current-password");
    expect(password).toBeRequired();

    expect(screen.getByRole("button", { name: "Entrar" })).toHaveAttribute("type", "submit");
  });

  it("a arte de nuvem é decorativa: aria-hidden e sem captura de ponteiro", () => {
    const { container } = renderLogin();
    const art = container.querySelector("[data-testid='login-art']") as HTMLElement;
    expect(art).not.toBeNull();
    expect(art).toHaveAttribute("aria-hidden", "true");
    expect(art.className).toContain("pointer-events-none");
    expect(art.querySelector("svg")).not.toBeNull();
    expect(art.querySelector("img")).toBeNull(); // arte inline, sem imagem pesada
    expect(art.querySelector("a, button, input")).toBeNull(); // nada focável na arte
  });

  it("desliga as animações da arte com prefers-reduced-motion", () => {
    const { container } = renderLogin();
    const css = Array.from(container.querySelectorAll("style")).map((s) => s.textContent).join("\n");
    expect(css).toMatch(/@keyframes/);
    expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\)\s*\{[^}]*\.login-cloud[^}]*animation:\s*none/s);
  });

  it("não deixa console.log com dados de login", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    signIn.mockResolvedValue({ data: { user: { id: "u1", role: "authenticated" } }, error: null } as never);
    renderLogin();
    fill();
    submit();
    await waitFor(() => expect(navigate).toHaveBeenCalled());
    expect(log).not.toHaveBeenCalled();
    log.mockRestore();
  });
});

describe("Login · comportamento preservado", () => {
  it("submete os valores digitados em signInWithPassword", async () => {
    signIn.mockResolvedValue({ data: { user: { id: "u1", role: "authenticated" } }, error: null } as never);
    renderLogin();
    fill("ana@nubo.com", "segredo123");
    submit();
    expect(signIn).toHaveBeenCalledWith({ email: "ana@nubo.com", password: "segredo123" });
    await waitFor(() => expect(navigate).toHaveBeenCalled());
  });

  it("campos e botão de envio vivem no mesmo <form>, então Enter envia", () => {
    renderLogin();
    const form = screen.getByLabelText("E-mail").closest("form") as HTMLFormElement;
    expect(form).not.toBeNull();
    expect(form).toContainElement(screen.getByLabelText("Senha"));
    expect(form).toContainElement(screen.getByRole("button", { name: "Entrar" }));
  });

  it("admin vai para / e mostra o toast de sucesso", async () => {
    signIn.mockResolvedValue({ data: { user: { id: "u1", role: "authenticated" } }, error: null } as never);
    renderLogin();
    fill();
    submit();
    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/"));
    expect(toastSuccess).toHaveBeenCalledWith("Autenticado com sucesso!");
  });

  it("usuário com role partner vai para /partner", async () => {
    signIn.mockResolvedValue({ data: { user: { id: "p1", role: "partner" } }, error: null } as never);
    renderLogin();
    fill();
    submit();
    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/partner"));
  });

  it("durante o envio o botão fica desabilitado, com estado de loading", async () => {
    let resolve!: (v: unknown) => void;
    signIn.mockReturnValue(new Promise((r) => (resolve = r)) as never);
    renderLogin();
    fill();
    submit();
    const busy = await screen.findByRole("button", { name: /Entrando/ });
    expect(busy).toBeDisabled();
    expect(busy).toHaveAttribute("aria-busy", "true");
    resolve({ data: { user: { id: "u1", role: "authenticated" } }, error: null });
    await waitFor(() => expect(navigate).toHaveBeenCalled());
  });
});

describe("Login · erros em PT-BR", () => {
  it("invalid_credentials → mensagem PT-BR inline em role=alert, sem navegar", async () => {
    signIn.mockResolvedValue({
      data: { user: null },
      error: { name: "AuthApiError", code: "invalid_credentials", status: 400, message: "Invalid login credentials" },
    } as never);
    renderLogin();
    fill();
    submit();

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("E-mail ou senha incorretos");
    expect(screen.queryByText(/Invalid login credentials/)).not.toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
    expect(screen.getByLabelText("E-mail")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("E-mail")).toHaveAttribute("aria-describedby", alert.id);
    expect(screen.getByRole("button", { name: "Entrar" })).toBeEnabled();
  });

  it("exceção de rede também vira mensagem PT-BR (não derruba a tela)", async () => {
    signIn.mockRejectedValue(new TypeError("Failed to fetch"));
    renderLogin();
    fill();
    submit();
    expect(await screen.findByRole("alert")).toHaveTextContent(/conexão/i);
  });

  it("o alerta some quando o usuário volta a digitar", async () => {
    signIn.mockResolvedValue({ data: { user: null }, error: { code: "invalid_credentials", status: 400, message: "x" } } as never);
    renderLogin();
    fill();
    submit();
    await screen.findByRole("alert");
    fireEvent.change(screen.getByLabelText("Senha"), { target: { value: "outra" } });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});

describe("loginErrorMessage", () => {
  it.each([
    [{ code: "invalid_credentials", status: 400, message: "Invalid login credentials" }, /E-mail ou senha incorretos/],
    [{ code: "email_not_confirmed", status: 400, message: "Email not confirmed" }, /confirm/i],
    [{ code: "over_request_rate_limit", status: 429, message: "rate" }, /tentativas|aguarde/i],
    [{ status: 429, message: "Too many requests" }, /tentativas|aguarde/i],
    [{ name: "AuthRetryableFetchError", status: 0, message: "Failed to fetch" }, /conexão/i],
    [new TypeError("Failed to fetch"), /conexão/i],
    [{ code: "unexpected_failure", status: 500, message: "boom" }, /Não foi possível entrar/],
    [null, /Não foi possível entrar/],
  ])("mapeia %j", (error, expected) => {
    const msg = loginErrorMessage(error);
    expect(msg).toMatch(expected);
    expect(msg).not.toMatch(/[A-Za-z]+ (login|credentials|confirmed|requests)/); // nada de inglês vazando
  });
});

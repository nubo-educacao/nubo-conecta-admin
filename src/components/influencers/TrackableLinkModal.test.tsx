import { render, screen } from "@testing-library/react";
import TrackableLinkModal from "./TrackableLinkModal";

vi.mock("sonner", () => ({
  toast: { success: vi.fn() },
}));

describe("TrackableLinkModal", () => {
  it("gera o link de afiliado com o domínio .org.br", () => {
    render(
      <TrackableLinkModal
        open
        onOpenChange={vi.fn()}
        influencerCode="embaixador-42"
      />,
    );

    const input = screen.getByLabelText("Link de Afiliado");

    expect(input).toHaveValue(
      "https://conecta.nuboeducacao.org.br/?ref=embaixador-42",
    );
    expect(input).not.toHaveValue(expect.stringContaining(".com.br"));
  });
});

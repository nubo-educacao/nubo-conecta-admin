import { readFileSync } from "node:fs";
import path from "node:path";
import postcss from "postcss";
import tailwindcss from "tailwindcss";
import { describe, expect, it } from "vitest";
import { render, screen, within } from "@testing-library/react";
import tailwindConfig from "../../../tailwind.config";
import { FunnelChart } from "./FunnelChart";

const read = (file: string) => readFileSync(path.resolve(__dirname, file), "utf8");
const CHART = read("FunnelChart.tsx");
const SECTION = read("GlobalFunnelSection.tsx");

async function generatedCss(...sources: string[]): Promise<string> {
  const result = await postcss([
    tailwindcss({
      ...tailwindConfig,
      content: sources.map((raw) => ({ raw, extension: "tsx" })),
    }),
  ]).process("@tailwind utilities;", { from: undefined });
  return result.css;
}

// Tailwind emite hex como `rgb(r g b / var(--tw-bg-opacity, 1))`.
function backgroundRgb(hex: string): string {
  return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)).join(" ");
}

describe("FunnelChart — cores das barras", () => {
  it("every bg-nubo-* class the chart uses exists in the generated CSS with the nubo blues", async () => {
    const used = [...new Set(CHART.match(/bg-nubo-[a-z-]+/g))].sort();
    expect(used).toEqual(["bg-nubo-primary", "bg-nubo-primary-dark"]);
    const css = await generatedCss(CHART);
    expect(css).toContain(`.bg-nubo-primary {\n    --tw-bg-opacity: 1;\n    background-color: rgb(${backgroundRgb("#3092bb")} /`);
    expect(css).toContain(`.bg-nubo-primary-dark {\n    --tw-bg-opacity: 1;\n    background-color: rgb(${backgroundRgb("#024F86")} /`);
  });

  it("generates the scoped primary-dark override GlobalFunnelSection applies to the Parceiro chart", async () => {
    const css = await generatedCss(CHART, SECTION);
    expect(css).toContain(
      `.\\[\\&_\\.bg-nubo-primary\\]\\:bg-nubo-primary-dark .bg-nubo-primary {\n    --tw-bg-opacity: 1;\n    background-color: rgb(${backgroundRgb("#024F86")} /`,
    );
  });
});

describe("FunnelChart — valor ausente com cobertura desconhecida", () => {
  it("does not pair a dash with 'volume observado' when there is no value", () => {
    render(
      <FunnelChart
        mode="observed_volumes"
        unitLabel="eventos"
        steps={[
          { key: "a", label: "Base", value: 10 },
          { key: "b", label: "Terminal", value: null, coverage: { status: "unknown" } },
        ]}
      />,
    );
    const step = screen.getAllByTestId("funnel-step")[1];
    expect(within(step).getByText("—")).toBeInTheDocument();
    expect(within(step).getByText(/Cobertura desconhecida/)).toBeInTheDocument();
    expect(within(step).queryByText(/volume observado/i)).not.toBeInTheDocument();
  });

  it("keeps 'volume observado' when the value is a real number under unknown or partial coverage", () => {
    render(
      <FunnelChart
        mode="observed_volumes"
        unitLabel="eventos"
        steps={[
          { key: "a", label: "Desconhecida", value: 3, coverage: { status: "unknown" } },
          { key: "b", label: "Parcial", value: 4, coverage: { status: "partial" } },
        ]}
      />,
    );
    expect(screen.getByText("Cobertura desconhecida — volume observado")).toBeInTheDocument();
    expect(screen.getByText("Cobertura parcial — volume observado")).toBeInTheDocument();
  });
});

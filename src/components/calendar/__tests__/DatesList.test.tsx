// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import React from "react";
import { render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import DatesList from "../DatesList";
import type { ImportantDate } from "@/services/calendarService";

describe("DatesList (admin)", () => {
  it("exibe datas com intervalo que transborda o mês selecionado (overlap)", () => {
    const dates: ImportantDate[] = [
      {
        id: "1",
        title: "Período Sisu 2026",
        description: "Inscrições abertas",
        start_date: "2026-06-25T00:00:00.000Z",
        end_date: "2026-07-05T23:59:59.000Z",
        type: "sisu",
        controls_opportunity_dates: false,
        created_at: "2026-06-01T00:00:00.000Z",
      },
    ];

    // Julho 2026
    const selectedMonth = new Date(2026, 6, 1);

    render(<DatesList dates={dates} selectedMonth={selectedMonth} />);

    expect(screen.getByText("Período Sisu 2026")).toBeInTheDocument();
    expect(screen.getByText("Sisu")).toBeInTheDocument();
  });
});

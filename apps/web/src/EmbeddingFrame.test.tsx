import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { EmbeddingFrame, isQuickSightUrl } from "./EmbeddingFrame";

vi.mock("amazon-quicksight-embedding-sdk", () => ({
  createEmbeddingContext: vi.fn(),
}));

describe("isQuickSightUrl", () => {
  it("accepts QuickSight hosts over HTTPS only", () => {
    expect(isQuickSightUrl("https://quicksight.aws.amazon.com/embed/x")).toBe(true);
    expect(isQuickSightUrl("https://us-east-1.quicksight.aws.amazon.com/embed/x")).toBe(true);
    expect(isQuickSightUrl("http://us-east-1.quicksight.aws.amazon.com/embed/x")).toBe(false);
    expect(isQuickSightUrl("https://quicksight.aws.amazon.com.evil.io/")).toBe(false);
    expect(isQuickSightUrl("https://evil.io/quicksight.aws.amazon.com")).toBe(false);
    expect(isQuickSightUrl("javascript:alert(1)")).toBe(false);
    expect(isQuickSightUrl("not a url")).toBe(false);
  });
});

describe("EmbeddingFrame", () => {
  const base = {
    title: "Pulso de Facturación",
    experience: "dashboard" as const,
    onRetry: vi.fn(),
  };

  it("shows a loading state while there is no URL", () => {
    render(<EmbeddingFrame {...base} />);
    expect(screen.getByText("Cargando Pulso de Facturación…")).toBeInTheDocument();
    expect(screen.queryByTitle("Pulso de Facturación")).not.toBeInTheDocument();
  });

  it("renders the dashboard iframe for a QuickSight URL", () => {
    render(
      <EmbeddingFrame {...base} url="https://us-east-1.quicksight.aws.amazon.com/embed/abc" />,
    );
    const iframe = screen.getByTitle("Pulso de Facturación");
    expect(iframe.tagName).toBe("IFRAME");
    expect(iframe).toHaveAttribute("src", "https://us-east-1.quicksight.aws.amazon.com/embed/abc");
    expect(iframe).toHaveAttribute("referrerpolicy", "strict-origin-when-cross-origin");
  });

  it("refuses to frame anything that is not QuickSight", () => {
    render(<EmbeddingFrame {...base} url="https://evil.io/embed" />);
    expect(screen.getByRole("alert")).toHaveTextContent(
      "La dirección recibida no es de Amazon Quick.",
    );
    expect(document.querySelector("iframe")).toBeNull();
  });

  it("shows the error with a retry action", async () => {
    const onRetry = vi.fn();
    render(<EmbeddingFrame {...base} error="Servicio no disponible" onRetry={onRetry} />);

    expect(screen.getByRole("alert")).toHaveTextContent("Servicio no disponible");
    await userEvent.click(screen.getByRole("button", { name: "Reintentar" }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });
});

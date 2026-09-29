import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ClientIdentity, initialsOf, Wordmark } from "./Brand";

describe("initialsOf", () => {
  it("drops legal suffixes and connectors", () => {
    expect(initialsOf("Empresa Inteligente S.A.")).toBe("EI");
    expect(initialsOf("Distribuidora del Norte, S.A.")).toBe("DN");
    expect(initialsOf("Café y Pan Ltda")).toBe("CP");
  });

  it("falls back to the first two letters of a single word", () => {
    expect(initialsOf("INFILE")).toBe("I");
    expect(initialsOf("S.A.")).toBe("SA");
  });
});

describe("Wordmark", () => {
  it("exposes the product name once to assistive tech and splits IN visually", () => {
    render(<Wordmark />);
    expect(screen.getByLabelText("INsight")).toBeInTheDocument();
    expect(screen.getByText("IN").tagName).toBe("B");
    expect(screen.getByText("by INFILE")).toBeInTheDocument();
  });

  it("can omit the vendor line", () => {
    render(<Wordmark withVendor={false} />);
    expect(screen.queryByText("by INFILE")).not.toBeInTheDocument();
  });
});

describe("ClientIdentity", () => {
  it("shows the client name with initials when there is no logo", () => {
    render(<ClientIdentity name="Empresa Inteligente S.A." />);
    expect(screen.getByText("Empresa Inteligente S.A.")).toBeInTheDocument();
    expect(screen.getByText("EI")).toBeInTheDocument();
  });

  it("prefers the logo when provided", () => {
    render(<ClientIdentity logoUrl="/logo.png" name="Empresa Inteligente S.A." />);
    expect(document.querySelector("img.client-logo")).toHaveAttribute("src", "/logo.png");
    expect(screen.queryByText("EI")).not.toBeInTheDocument();
  });

  it("falls back to a generic label without a configured client", () => {
    render(<ClientIdentity />);
    expect(screen.getByText("Espacio de trabajo")).toBeInTheDocument();
  });
});

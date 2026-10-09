import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App, { suggestedPrompts } from "./App";
import { config, tokenExpiringIn } from "./test/fixtures";

const auth = vi.hoisted(() => ({
  resolveSession: vi.fn(),
  signIn: vi.fn(),
  signOut: vi.fn(),
  clearToken: vi.fn(),
}));

vi.mock("./auth", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./auth")>();
  return { ...actual, ...auth };
});

const api = vi.hoisted(() => ({
  getEmbedUrl: vi.fn(),
  getFreshness: vi.fn(),
}));

vi.mock("./api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./api")>();
  return { ...actual, ...api };
});

vi.mock("./EmbeddingFrame", () => ({
  EmbeddingFrame: ({
    url,
    initialPrompt,
    experience,
    chatAgentId,
  }: {
    url?: string;
    initialPrompt?: string;
    experience: string;
    chatAgentId?: string;
  }) => (
    <div
      data-testid="frame"
      data-url={url ?? ""}
      data-prompt={initialPrompt ?? ""}
      data-experience={experience}
      data-agent={chatAgentId ?? ""}
    />
  ),
}));

const EMBED = "https://us-east-1.quicksight.aws.amazon.com/embed/";

beforeEach(() => {
  let counter = 0;
  api.getEmbedUrl.mockImplementation(async (_config, _token, experience: string) => ({
    embedUrl: `${EMBED}${experience}-${++counter}`,
    expiresAt: "2026-09-28T13:00:00Z",
  }));
  api.getFreshness.mockResolvedValue({
    lastRefreshAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    refreshing: false,
    datasets: [],
  });
});

afterEach(() => vi.clearAllMocks());

const signedIn = () =>
  auth.resolveSession.mockResolvedValue({
    config,
    idToken: tokenExpiringIn(3600),
    refreshToken: "rt",
  });

describe("App (unauthenticated)", () => {
  it("shows the branded landing and opens Managed Login on demand", async () => {
    auth.resolveSession.mockResolvedValue({ config });
    render(<App splashMs={0} />);

    const button = await screen.findByRole("button", { name: /Iniciar sesión/ });
    expect(screen.queryByText("Empresa Inteligente S.A.")).not.toBeInTheDocument();
    expect(screen.getByLabelText("INsight")).toBeInTheDocument();
    expect(screen.getByText("Insight desde adentro de su facturación.")).toBeInTheDocument();
    expect(auth.signIn).not.toHaveBeenCalled();

    await userEvent.click(button);
    expect(auth.signIn).toHaveBeenCalledWith(config);
    expect(api.getEmbedUrl).not.toHaveBeenCalled();
  });

  it("keeps the splash up for the minimum time even when the session is ready", async () => {
    vi.useFakeTimers();
    try {
      signedIn();
      render(<App splashMs={1400} />);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(800);
      });
      expect(screen.getByRole("main")).toHaveAttribute("aria-busy", "true");
      expect(screen.queryByRole("heading", { level: 1 })).not.toBeInTheDocument();

      await act(async () => {
        await vi.advanceTimersByTimeAsync(700);
      });
      expect(
        screen.getByRole("heading", { level: 1, name: "Analista de Ventas" }),
      ).toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("shows the sign-in error with a retry button", async () => {
    auth.resolveSession.mockResolvedValue({
      config,
      error: "La respuesta de inicio de sesión no es válida.",
    });
    render(<App splashMs={0} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("no es válida");
    await userEvent.click(screen.getByRole("button", { name: "Volver a intentar" }));
    expect(auth.signIn).toHaveBeenCalledTimes(1);
  });

  it("shows a boot error when the configuration cannot be loaded", async () => {
    auth.resolveSession.mockRejectedValue(
      new Error("No se encontró la configuración de la aplicación (config.json)."),
    );
    render(<App splashMs={0} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("config.json");
    expect(screen.getByRole("button", { name: /Volver a intentar/ })).toBeInTheDocument();
  });
});

describe("App (authenticated)", () => {
  beforeEach(signedIn);

  it("opens the chat first with suggested questions and the no-history notice", async () => {
    render(<App splashMs={0} />);

    expect(
      await screen.findByRole("heading", { level: 1, name: "Analista de Ventas" }),
    ).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-1`),
    );
    expect(screen.getByText(/Las conversaciones no se guardan/)).toBeInTheDocument();
    for (const suggestion of suggestedPrompts) {
      expect(screen.getByRole("button", { name: suggestion.short })).toBeEnabled();
    }
    expect(screen.getByRole("button", { name: "Nueva conversación" })).toBeEnabled();
    // Data status appears in the sidebar (desktop) and the topbar badge (mobile).
    expect(await screen.findAllByText("actualizado hace 5 min")).toHaveLength(2);
    // Signed-in identity comes from the ID token claims.
    expect(screen.getByText("ana@example.com")).toBeInTheDocument();
    // The client owns the workspace (sidebar + mobile header); the product stays in the footer.
    expect(screen.getAllByText("Empresa Inteligente S.A.").length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("Empresa Inteligente S.A. · Ventas")).toBeInTheDocument();
    expect(screen.getAllByLabelText("INsight").length).toBeGreaterThanOrEqual(1);
    expect(document.title).toBe("INsight · Empresa Inteligente S.A.");
  });

  it("collapses the suggestions once a question is sent and reopens them for a new conversation", async () => {
    render(<App splashMs={0} />);
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-1`),
    );

    await userEvent.click(screen.getByRole("button", { name: suggestedPrompts[1]!.short }));
    expect(
      screen.queryByRole("button", { name: suggestedPrompts[1]!.short }),
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Sugerencias/ })).toHaveAttribute(
      "aria-expanded",
      "false",
    );

    await userEvent.click(screen.getByRole("button", { name: /Sugerencias/ }));
    expect(screen.getByRole("button", { name: suggestedPrompts[1]!.short })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /Ocultar/ }));
    expect(
      screen.queryByRole("button", { name: suggestedPrompts[1]!.short }),
    ).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "Nueva conversación" }));
    expect(screen.getByRole("button", { name: suggestedPrompts[1]!.short })).toBeInTheDocument();
  });

  it("switches to the dashboard and back without reloading the active view", async () => {
    render(<App splashMs={0} />);
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-1`),
    );

    const nav = screen.getByRole("navigation", { name: "Navegación principal" });
    await userEvent.click(nav.querySelector('button[aria-current="page"]')!);
    expect(api.getEmbedUrl).toHaveBeenCalledTimes(1);

    await userEvent.click(screen.getAllByRole("button", { name: /Pulso comercial/ })[0]!);
    expect(
      await screen.findByRole("heading", { level: 1, name: "Pulso de Facturación" }),
    ).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}dashboard-2`),
    );
    expect(screen.getByTestId("frame")).toHaveAttribute("data-experience", "dashboard");
  });

  it("sends a suggested question to a fresh chat", async () => {
    render(<App splashMs={0} />);
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-1`),
    );

    await userEvent.click(screen.getByRole("button", { name: suggestedPrompts[0]!.short }));

    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-2`),
    );
    expect(screen.getByTestId("frame")).toHaveAttribute("data-prompt", suggestedPrompts[0]!.prompt);
  });

  it("starts a new conversation on demand", async () => {
    render(<App splashMs={0} />);
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-1`),
    );

    await userEvent.click(screen.getByRole("button", { name: "Nueva conversación" }));
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-url", `${EMBED}chat-2`),
    );
    expect(screen.getByTestId("frame")).toHaveAttribute("data-prompt", "");
  });

  it("pins the chat to the agent the API chose for this identity", async () => {
    api.getEmbedUrl.mockResolvedValue({
      embedUrl: `${EMBED}chat-9`,
      expiresAt: "2026-09-28T13:00:00Z",
      agentId: "agente-de-la-api",
    });
    render(<App splashMs={0} />);

    await screen.findByRole("heading", { level: 1 });
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-agent", "agente-de-la-api"),
    );
  });

  it("falls back to the configured agent when the API returns none", async () => {
    render(<App splashMs={0} />);

    await screen.findByRole("heading", { level: 1 });
    await waitFor(() =>
      expect(screen.getByTestId("frame")).toHaveAttribute("data-agent", config.quickChatAgentId!),
    );
  });

  it("ends the session when the API says the token expired", async () => {
    const { SessionExpiredError } = await import("./api");
    api.getEmbedUrl.mockRejectedValue(new SessionExpiredError());
    render(<App splashMs={0} />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Tu sesión expiró");
    expect(auth.clearToken).toHaveBeenCalled();
  });

  it("shows the service as unavailable when the embed fails", async () => {
    api.getEmbedUrl.mockRejectedValue(
      new Error("No fue posible iniciar la experiencia de análisis."),
    );
    render(<App splashMs={0} />);

    expect(await screen.findAllByText("Servicio no disponible")).toHaveLength(2);
    expect(screen.getByRole("button", { name: "Nueva conversación" })).toBeDisabled();
    for (const suggestion of suggestedPrompts) {
      expect(screen.getByRole("button", { name: suggestion.short })).toBeDisabled();
    }
  });

  it("signs out from the sidebar", async () => {
    render(<App splashMs={0} />);
    await screen.findByRole("heading", { level: 1 });
    await userEvent.click(screen.getAllByRole("button", { name: "Cerrar sesión" })[0]!);
    expect(auth.signOut).toHaveBeenCalledWith(config);
  });
});

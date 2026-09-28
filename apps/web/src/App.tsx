import { useCallback, useEffect, useRef, useState } from "react";
import {
  describeAge,
  getEmbedUrl,
  getFreshness,
  SessionExpiredError,
  type EmbedExperience,
  type FreshnessResponse,
} from "./api";
import { clearToken, msUntilExpiry, resolveSession, signIn, signOut, type Session } from "./auth";
import { EmbeddingFrame } from "./EmbeddingFrame";

type View = "overview" | "chat";

const viewToExperience: Record<View, EmbedExperience> = {
  overview: "dashboard",
  chat: "chat",
};

const navItems: Array<{ id: View; label: string; mobileLabel: string; icon: string }> = [
  { id: "chat", label: "Nueva consulta", mobileLabel: "Consulta", icon: "✦" },
  { id: "overview", label: "Pulso comercial", mobileLabel: "Pulso", icon: "▦" },
];

const viewCopy: Record<View, { title: string; description: string }> = {
  overview: {
    title: "Pulso de Facturación",
    description: "Indicadores y evolución de la facturación emitida.",
  },
  chat: {
    title: "Analista de Ventas",
    description: "Pregunte por facturación, facturas, clientes, productos, regiones y comparativos.",
  },
};

const suggestedPrompts = [
  {
    icon: "↗",
    eyebrow: "TENDENCIA",
    title: "Comparar períodos",
    prompt: "Compara la facturación del último mes completo con el mes anterior. Incluye ambos valores y la variación porcentual.",
  },
  {
    icon: "◎",
    eyebrow: "REGIONES",
    title: "Ver líderes",
    prompt: "¿Cuáles fueron las 5 regiones con mayor facturación en los últimos 30 días? Muéstralo como barras ordenadas.",
  },
  {
    icon: "◇",
    eyebrow: "PRODUCTOS",
    title: "Encontrar el top 5",
    prompt: "¿Cuáles fueron los 5 productos con mayor facturación en el último mes completo? Incluye el monto en quetzales.",
  },
  {
    icon: "◷",
    eyebrow: "CLIENTES",
    title: "Analizar clientes",
    prompt: "¿Quiénes fueron los 5 clientes con mayor facturación en el último mes completo? Incluye el total en quetzales.",
  },
] as const;

function NavButtons({ activeView, onSelect, compact = false }: {
  activeView: View;
  onSelect: (view: View) => void;
  compact?: boolean;
}) {
  return navItems.map((item) => (
    <button
      aria-current={activeView === item.id ? "page" : undefined}
      className={activeView === item.id ? "nav-item active" : "nav-item"}
      key={item.id}
      onClick={() => onSelect(item.id)}
      type="button"
    >
      <span aria-hidden="true">{item.icon}</span>
      {compact ? item.mobileLabel : item.label}
    </button>
  ));
}

export default function App() {
  const [session, setSession] = useState<Session>();
  const [activeView, setActiveView] = useState<View>("chat");
  const [embedUrl, setEmbedUrl] = useState<string>();
  const [error, setError] = useState<string>();
  const [freshness, setFreshness] = useState<FreshnessResponse>();
  const [pendingPrompt, setPendingPrompt] = useState<string>();
  const requestSeq = useRef(0);
  const loginRedirectStarted = useRef(false);

  useEffect(() => {
    resolveSession()
      .then(setSession)
      .catch((caught: unknown) =>
        setError(caught instanceof Error ? caught.message : "No fue posible iniciar la aplicación."),
      );
  }, []);

  // No application-specific landing page before authentication: as soon as
  // config/session resolution proves there is no valid token, open Cognito's
  // Managed Login. Its own screen also contains the corporate sign-up link.
  useEffect(() => {
    if (!session || session.idToken || session.error || error || loginRedirectStarted.current) return;
    loginRedirectStarted.current = true;
    void signIn(session.config);
  }, [session, error]);

  const endSession = useCallback((reason: string) => {
    clearToken();
    setEmbedUrl(undefined);
    setError(undefined);
    setSession((current) => (current ? { config: current.config, error: reason } : current));
  }, []);

  useEffect(() => {
    if (!session?.idToken) return;
    const timer = window.setTimeout(
      () => endSession("Tu sesión expiró. Inicia sesión de nuevo."),
      Math.max(msUntilExpiry(session.idToken), 0),
    );
    return () => window.clearTimeout(timer);
  }, [session, endSession]);

  const loadExperience = useCallback(
    async (view: View) => {
      if (!session?.idToken) return;
      const seq = ++requestSeq.current;
      setEmbedUrl(undefined);
      setError(undefined);

      try {
        const response = await getEmbedUrl(session.config, session.idToken, viewToExperience[view]);
        if (seq === requestSeq.current) setEmbedUrl(response.embedUrl);
      } catch (caught) {
        if (seq !== requestSeq.current) return;
        if (caught instanceof SessionExpiredError) {
          endSession(caught.message);
          return;
        }
        setError(caught instanceof Error ? caught.message : "Ocurrió un error inesperado.");
      }
    },
    [session, endSession],
  );

  useEffect(() => {
    void loadExperience(activeView);
  }, [activeView, loadExperience]);

  useEffect(() => {
    if (!session?.idToken) return;

    const read = () =>
      getFreshness(session.config, session.idToken!)
        .then(setFreshness)
        .catch((caught: unknown) => {
          if (caught instanceof SessionExpiredError) endSession(caught.message);
        });

    void read();
    const timer = window.setInterval(read, 60_000);
    return () => window.clearInterval(timer);
  }, [session, endSession]);

  const askSuggestedPrompt = (prompt: string) => {
    setPendingPrompt(prompt);
    setActiveView("chat");
  };

  const selectView = (view: View) => {
    if (view !== "chat") setPendingPrompt(undefined);

    // Clicking the active destination means "open it fresh". This is
    // especially important for chat: Quick embed URLs are one-use and a shared
    // pilot identity should always start a clean private conversation.
    if (view === activeView) {
      void loadExperience(view);
      return;
    }
    setActiveView(view);
  };

  if (!session) {
    return (
      <main className="auth-redirect" aria-live="polite">
        <span aria-hidden="true" className="brand-mark">↗</span>
        <span className="loading-mark small" />
        <span className="sr-only">Abriendo inicio de sesión…</span>
      </main>
    );
  }

  if (!session.idToken && !session.error && !error) {
    return (
      <main className="auth-redirect" aria-live="polite">
        <span aria-hidden="true" className="brand-mark">↗</span>
        <span className="loading-mark small" />
        <span className="sr-only">Abriendo inicio de sesión…</span>
      </main>
    );
  }

  if (!session.idToken) {
    return (
      <main className="gate">
        <div className="gate-card">
          <span className="brand-mark">↗</span>
          <h1>Ventas Inteligentes</h1>
          <p className="gate-error" role="alert">
            {session.error ?? error ?? "No fue posible iniciar sesión."}
          </p>
          <button className="primary-button" onClick={() => void signIn(session.config)} type="button">
            Volver a intentar
          </button>
        </div>
      </main>
    );
  }

  const { title: pageTitle, description: pageDescription } = viewCopy[activeView];
  const freshnessText = freshness?.refreshing
    ? "Actualizando datos…"
    : describeAge(freshness?.lastRefreshAt ?? null);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">↗</span>
          <span>Ventas Inteligentes</span>
        </div>
        <p className="workspace-label">Espacio de trabajo</p>
        <nav aria-label="Navegación principal">
          <NavButtons activeView={activeView} onSelect={selectView} />
        </nav>
        <div className="sidebar-footer">
          <span title={freshness?.lastRefreshAt ?? undefined}>
            <i aria-hidden="true" className={freshness?.refreshing ? "status-dot refreshing" : "status-dot"} />
            {freshnessText}
          </span>
          <small>Guatemala · GTQ · UTC-06:00</small>
          <button className="link-button" onClick={() => signOut(session.config)} type="button">
            Cerrar sesión
          </button>
        </div>
      </aside>

      <header className="mobile-header">
        <div className="brand">
          <span className="brand-mark">↗</span>
          <span>Ventas Inteligentes</span>
        </div>
        <button aria-label="Cerrar sesión" className="mobile-signout" onClick={() => signOut(session.config)} type="button">
          Salir
        </button>
      </header>

      <main className="main-content">
        <header className="topbar">
          <div>
            <p className="eyebrow">VENTAS · GUATEMALA</p>
            <h1>{pageTitle}</h1>
            <p className="subtitle">{pageDescription}</p>
          </div>
          <div className="context-badges">
            <div className="data-badge" title={freshness?.lastRefreshAt ?? undefined}>
              <i aria-hidden="true" className={freshness?.refreshing ? "status-dot refreshing" : "status-dot"} />
              {freshnessText}
            </div>
            <div
              className="topbar-badge"
              aria-live="polite"
              title={error ? undefined : "Facturación, facturas, unidades, clientes, productos, regiones y comparativos"}
            >
              <i aria-hidden="true" className={error ? "status-dot error" : "status-dot"} />
              {error ? "Servicio no disponible" : "Datos de ventas disponibles"}
            </div>
          </div>
        </header>

        {activeView === "chat" && (
          <section aria-labelledby="chat-invitation-title" className="chat-invitation">
            <span aria-hidden="true" className="chat-invitation-icon">✦</span>
            <div className="chat-invitation-copy">
              <p className="eyebrow">SUS DATOS TIENEN MUCHO QUE CONTAR</p>
              <h2 id="chat-invitation-title">Converse con sus ventas</h2>
              <p>Pregunte en lenguaje natural y descubra qué está impulsando sus resultados.</p>
            </div>
            <div aria-label="Ejemplos de preguntas" className="chat-question-examples">
              <span>“¿Cómo vamos este mes?”</span>
              <span>“¿Qué producto lidera?”</span>
            </div>
          </section>
        )}

        {activeView === "overview" && (
          <section aria-labelledby="quick-questions-title" className="quick-questions">
            <div className="section-heading">
              <div>
                <p className="eyebrow">CONSULTAS RÁPIDAS</p>
                <h2 id="quick-questions-title">Explora tus resultados</h2>
              </div>
              <button className="text-action" onClick={() => setActiveView("chat")} type="button">
                Abrir chat <span aria-hidden="true">→</span>
              </button>
            </div>
            <div className="prompt-grid">
              {suggestedPrompts.map((suggestion) => (
                <button
                  className="prompt-card"
                  key={suggestion.prompt}
                  onClick={() => askSuggestedPrompt(suggestion.prompt)}
                  type="button"
                >
                  <span aria-hidden="true" className="prompt-icon">{suggestion.icon}</span>
                  <span>
                    <small>{suggestion.eyebrow}</small>
                    <strong>{suggestion.title}</strong>
                  </span>
                  <span aria-hidden="true" className="prompt-arrow">→</span>
                </button>
              ))}
            </div>
          </section>
        )}

        {activeView === "chat" && pendingPrompt && !embedUrl && (
          <div className="prompt-status" aria-live="polite">
            <span className="loading-mark small" /> Preparando tu análisis…
          </div>
        )}

        <section className={activeView === "chat" ? "experience-card chat-card" : "experience-card"}>
          <EmbeddingFrame
            chatAgentId={session.config.quickChatAgentId}
            error={error}
            experience={viewToExperience[activeView]}
            initialPrompt={activeView === "chat" ? pendingPrompt : undefined}
            onChatReady={() => setPendingPrompt(undefined)}
            onRetry={() => void loadExperience(activeView)}
            title={pageTitle}
            url={embedUrl}
          />
        </section>
      </main>

      <nav aria-label="Navegación móvil" className="mobile-nav">
        <NavButtons activeView={activeView} compact onSelect={selectView} />
      </nav>
    </div>
  );
}

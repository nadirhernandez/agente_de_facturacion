import { useCallback, useEffect, useRef, useState } from "react";
import {
  describeAge,
  getEmbedUrl,
  getFreshness,
  SessionExpiredError,
  type EmbedExperience,
  type FreshnessResponse,
} from "./api";
import { clearToken, resolveSession, signIn, signOut, type Session, type Tokens } from "./auth";
import { EmbeddingFrame } from "./EmbeddingFrame";
import { useSessionKeepAlive } from "./useSessionKeepAlive";

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
    description:
      "Pregunte por facturación, facturas, clientes, productos, regiones y comparativos.",
  },
};

export const suggestedPrompts = [
  {
    icon: "↗",
    eyebrow: "TENDENCIA",
    title: "Comparar períodos",
    short: "¿Cómo vamos frente al mes pasado?",
    prompt:
      "Compara la facturación del último mes completo con el mes anterior. Incluye ambos valores y la variación porcentual.",
  },
  {
    icon: "◎",
    eyebrow: "REGIONES",
    title: "Ver líderes",
    short: "¿Qué regiones lideran?",
    prompt:
      "¿Cuáles fueron las 5 regiones con mayor facturación en los últimos 30 días? Muéstralo como barras ordenadas.",
  },
  {
    icon: "◇",
    eyebrow: "PRODUCTOS",
    title: "Encontrar el top 5",
    short: "¿Qué productos venden más?",
    prompt:
      "¿Cuáles fueron los 5 productos con mayor facturación en el último mes completo? Incluye el monto en quetzales.",
  },
  {
    icon: "◷",
    eyebrow: "CLIENTES",
    title: "Analizar clientes",
    short: "¿Quiénes son los mejores clientes?",
    prompt:
      "¿Quiénes fueron los 5 clientes con mayor facturación en el último mes completo? Incluye el total en quetzales.",
  },
] as const;

/** What the embed area is showing for the current view. */
interface EmbedState {
  view: View;
  url?: string;
  error?: string;
}

function NavButtons({
  activeView,
  onSelect,
  compact = false,
}: {
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

function AuthRedirect() {
  return (
    <main className="auth-redirect" aria-live="polite">
      <span aria-hidden="true" className="brand-mark">
        ↗
      </span>
      <span className="loading-mark small" />
      <span className="sr-only">Abriendo inicio de sesión…</span>
    </main>
  );
}

export default function App() {
  const [session, setSession] = useState<Session>();
  const [activeView, setActiveView] = useState<View>("chat");
  const [embed, setEmbed] = useState<EmbedState>();
  const [bootError, setBootError] = useState<string>();
  const [freshness, setFreshness] = useState<FreshnessResponse>();
  const [pendingPrompt, setPendingPrompt] = useState<string>();
  const requestSeq = useRef(0);
  const loginRedirectStarted = useRef(false);

  const endSession = useCallback((reason: string) => {
    clearToken();
    setEmbed(undefined);
    setSession((current) => (current ? { config: current.config, error: reason } : current));
  }, []);

  const applyTokens = useCallback((tokens: Tokens) => {
    setSession((current) => (current ? { ...current, ...tokens } : current));
  }, []);

  const sessionWarning = useSessionKeepAlive({
    session,
    onTokens: applyTokens,
    onExpired: endSession,
  });

  /**
   * Requests a fresh embed URL for a view. Always called from an event or a
   * resolved promise, never synchronously inside an effect, so the embed area
   * never renders an intermediate state. The sequence number discards stale
   * responses when the user navigates quickly.
   */
  const loadExperience = useCallback(
    async (view: View, auth: Session | undefined, prompt?: string) => {
      if (!auth?.idToken) return;
      const seq = ++requestSeq.current;
      setActiveView(view);
      setPendingPrompt(view === "chat" ? prompt : undefined);
      setEmbed({ view });

      try {
        const response = await getEmbedUrl(auth.config, auth.idToken, viewToExperience[view]);
        if (seq === requestSeq.current) setEmbed({ view, url: response.embedUrl });
      } catch (caught) {
        if (seq !== requestSeq.current) return;
        if (caught instanceof SessionExpiredError) {
          endSession(caught.message);
          return;
        }
        setEmbed({
          view,
          error: caught instanceof Error ? caught.message : "Ocurrió un error inesperado.",
        });
      }
    },
    [endSession],
  );

  useEffect(() => {
    resolveSession()
      .then((resolved) => {
        setSession(resolved);
        void loadExperience("chat", resolved);
      })
      .catch((caught: unknown) =>
        setBootError(
          caught instanceof Error ? caught.message : "No fue posible iniciar la aplicación.",
        ),
      );
  }, [loadExperience]);

  // No application-specific landing page before authentication: as soon as
  // config/session resolution proves there is no valid token, open Cognito's
  // Managed Login. Its own screen also contains the corporate sign-up link.
  useEffect(() => {
    if (!session || session.idToken || session.error || bootError || loginRedirectStarted.current) {
      return;
    }
    loginRedirectStarted.current = true;
    void signIn(session.config);
  }, [session, bootError]);

  const idToken = session?.idToken;
  const config = session?.config;

  useEffect(() => {
    if (!config || !idToken) return;

    const read = () =>
      getFreshness(config, idToken)
        .then(setFreshness)
        .catch((caught: unknown) => {
          if (caught instanceof SessionExpiredError) endSession(caught.message);
        });

    void read();
    const timer = window.setInterval(read, 60_000);
    return () => window.clearInterval(timer);
  }, [config, idToken, endSession]);

  const askSuggestedPrompt = (prompt: string) => void loadExperience("chat", session, prompt);

  const selectView = (view: View) => {
    // The active destination is already on screen; nothing to reload.
    if (view === activeView) return;
    void loadExperience(view, session);
  };

  if (!session) return bootError ? <BootError message={bootError} /> : <AuthRedirect />;
  if (!session.idToken && !session.error && !bootError) return <AuthRedirect />;

  if (!session.idToken) {
    return (
      <main className="gate">
        <div className="gate-card">
          <span className="brand-mark">↗</span>
          <h1>Ventas Inteligentes</h1>
          <p className="gate-error" role="alert">
            {session.error ?? bootError ?? "No fue posible iniciar sesión."}
          </p>
          <button
            className="primary-button"
            onClick={() => void signIn(session.config)}
            type="button"
          >
            Volver a intentar
          </button>
        </div>
      </main>
    );
  }

  const { title: pageTitle, description: pageDescription } = viewCopy[activeView];
  const current = embed?.view === activeView ? embed : undefined;
  const embedUrl = current?.url;
  const embedError = current?.error;

  const statusBadge = embedError
    ? { className: "status-badge error", text: "Servicio no disponible", title: undefined }
    : freshness?.refreshing
      ? { className: "status-badge refreshing", text: "Actualizando datos…", title: undefined }
      : {
          className: "status-badge",
          text: describeAge(freshness?.lastRefreshAt ?? null),
          title: freshness?.lastRefreshAt ?? undefined,
        };

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
        <button
          aria-label="Cerrar sesión"
          className="mobile-signout"
          onClick={() => signOut(session.config)}
          type="button"
        >
          Salir
        </button>
      </header>

      <main className="main-content">
        {sessionWarning && (
          <div className="session-warning" role="status">
            <i aria-hidden="true" className="status-dot refreshing" />
            {sessionWarning}
          </div>
        )}

        <header className="topbar">
          <div>
            <p className="eyebrow">VENTAS · GUATEMALA</p>
            <h1>{pageTitle}</h1>
            <p className="subtitle">{pageDescription}</p>
          </div>
          <div className="context-badges">
            <div aria-live="polite" className={statusBadge.className} title={statusBadge.title}>
              <i aria-hidden="true" className="status-dot" />
              {statusBadge.text}
            </div>
            {activeView === "chat" && (
              <button
                className="secondary-button compact"
                disabled={!embedUrl}
                onClick={() => void loadExperience("chat", session)}
                type="button"
              >
                Nueva conversación
              </button>
            )}
          </div>
        </header>

        {activeView === "chat" && (
          <section aria-labelledby="chat-invitation-title" className="chat-invitation">
            <span aria-hidden="true" className="chat-invitation-icon">
              ✦
            </span>
            <div className="chat-invitation-copy">
              <p className="eyebrow">SUS DATOS TIENEN MUCHO QUE CONTAR</p>
              <h2 id="chat-invitation-title">Converse con sus ventas</h2>
              <p className="chat-invitation-lead">
                Pregunte en lenguaje natural o empiece con una de estas preguntas.
              </p>
              <p className="chat-invitation-note">
                Las conversaciones no se guardan: cada visita empieza en blanco.
              </p>
            </div>
            <div className="chat-question-examples">
              {suggestedPrompts.map((suggestion) => (
                <button
                  className="chat-chip"
                  key={suggestion.prompt}
                  onClick={() => askSuggestedPrompt(suggestion.prompt)}
                  type="button"
                >
                  {suggestion.short}
                </button>
              ))}
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
              <button className="text-action" onClick={() => selectView("chat")} type="button">
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
                  <span aria-hidden="true" className="prompt-icon">
                    {suggestion.icon}
                  </span>
                  <span>
                    <small>{suggestion.eyebrow}</small>
                    <strong>{suggestion.title}</strong>
                  </span>
                  <span aria-hidden="true" className="prompt-arrow">
                    →
                  </span>
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

        <section
          className={activeView === "chat" ? "experience-card chat-card" : "experience-card"}
        >
          <EmbeddingFrame
            chatAgentId={session.config.quickChatAgentId}
            error={embedError}
            experience={viewToExperience[activeView]}
            initialPrompt={activeView === "chat" ? pendingPrompt : undefined}
            onChatReady={() => setPendingPrompt(undefined)}
            onRetry={() => void loadExperience(activeView, session, pendingPrompt)}
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

function BootError({ message }: { message: string }) {
  return (
    <main className="gate">
      <div className="gate-card">
        <span className="brand-mark">↗</span>
        <h1>Ventas Inteligentes</h1>
        <p className="gate-error" role="alert">
          {message}
        </p>
        <button className="primary-button" onClick={() => window.location.reload()} type="button">
          Recargar
        </button>
      </div>
    </main>
  );
}

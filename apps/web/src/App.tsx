import { useCallback, useEffect, useRef, useState } from "react";
import {
  describeAge,
  getEmbedUrl,
  getFreshness,
  SessionExpiredError,
  type EmbedExperience,
  type FreshnessResponse,
} from "./api";
import {
  clearToken,
  resolveSession,
  signIn,
  signOut,
  tokenEmail,
  type Session,
  type Tokens,
} from "./auth";
import { ClientIdentity, PRODUCT_NAME, Wordmark } from "./Brand";
import { EmbeddingFrame } from "./EmbeddingFrame";
import { Icon, type IconName } from "./Icon";
import { Landing, Splash, SPLASH_MS } from "./Splash";
import { useSessionKeepAlive } from "./useSessionKeepAlive";

type View = "overview" | "chat";

const viewToExperience: Record<View, EmbedExperience> = {
  overview: "dashboard",
  chat: "chat",
};

const navItems: Array<{ id: View; label: string; mobileLabel: string; icon: IconName }> = [
  { id: "chat", label: "Nueva consulta", mobileLabel: "Consulta", icon: "sparkles" },
  { id: "overview", label: "Pulso comercial", mobileLabel: "Pulso", icon: "dashboard" },
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

export const suggestedPrompts: ReadonlyArray<{
  icon: IconName;
  eyebrow: string;
  title: string;
  short: string;
  prompt: string;
}> = [
  {
    icon: "trending-up",
    eyebrow: "TENDENCIA",
    title: "Comparar períodos",
    short: "¿Cómo vamos vs. el mes pasado?",
    prompt:
      "Compara la facturación del último mes completo con el mes anterior, por moneda. Incluye ambos valores y la variación porcentual.",
  },
  {
    icon: "map-pin",
    eyebrow: "REGIONES",
    title: "Ver líderes",
    short: "¿Qué regiones lideran?",
    prompt:
      "¿Cuáles fueron las 5 regiones con mayor facturación en los últimos 30 días? Separa GTQ y USD y muéstralo como barras ordenadas.",
  },
  {
    icon: "package",
    eyebrow: "PRODUCTOS",
    title: "Encontrar el top 5",
    short: "¿Qué productos venden más?",
    prompt:
      "¿Cuáles fueron los 5 productos con mayor facturación en USD en el último mes completo? Incluye el monto en dólares.",
  },
  {
    icon: "users",
    eyebrow: "CLIENTES",
    title: "Analizar clientes",
    short: "¿Quiénes compran más?",
    prompt:
      "¿Quiénes fueron los 5 clientes con mayor facturación en GTQ en el último mes completo? Incluye el total en quetzales.",
  },
];

/** What the embed area is showing for the current view. */
interface EmbedState {
  view: View;
  url?: string;
  error?: string;
}

const exactTime = (iso: string) =>
  new Date(iso).toLocaleString("es-GT", {
    timeZone: "America/Guatemala",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });

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
      <Icon name={item.icon} />
      {compact ? item.mobileLabel : item.label}
    </button>
  ));
}

/** Keeps the splash on screen for at least `ms` after mount. */
function useMinimumSplash(ms: number): boolean {
  const [done, setDone] = useState(ms <= 0);
  useEffect(() => {
    if (ms <= 0) return;
    const timer = window.setTimeout(() => setDone(true), ms);
    return () => window.clearTimeout(timer);
  }, [ms]);
  return done;
}

interface StatusInfo {
  tone: "ok" | "refreshing" | "error";
  text: string;
  detail?: string;
}

function statusFrom(
  freshness: FreshnessResponse | undefined,
  error: string | undefined,
): StatusInfo {
  if (error) return { tone: "error", text: "Servicio no disponible" };
  if (freshness?.refreshing) return { tone: "refreshing", text: "Actualizando datos…" };
  return {
    tone: "ok",
    text: describeAge(freshness?.lastRefreshAt ?? null),
    detail: freshness?.lastRefreshAt ? exactTime(freshness.lastRefreshAt) : undefined,
  };
}

export default function App({ splashMs = SPLASH_MS }: { splashMs?: number } = {}) {
  const splashDone = useMinimumSplash(splashMs);
  const [session, setSession] = useState<Session>();
  const [activeView, setActiveView] = useState<View>("chat");
  const [embed, setEmbed] = useState<EmbedState>();
  const [bootError, setBootError] = useState<string>();
  const [freshness, setFreshness] = useState<FreshnessResponse>();
  const [pendingPrompt, setPendingPrompt] = useState<string>();
  const [suggestionsOpen, setSuggestionsOpen] = useState(true);
  const requestSeq = useRef(0);

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

  const idToken = session?.idToken;
  const config = session?.config;

  // Browser tab: "INsight · Empresa Inteligente S.A."
  useEffect(() => {
    document.title = config?.clientName ? `${PRODUCT_NAME} · ${config.clientName}` : PRODUCT_NAME;
  }, [config?.clientName]);

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

  const askSuggestedPrompt = (prompt: string) => {
    // The person has started a conversation: get the banner out of the way.
    setSuggestionsOpen(false);
    void loadExperience("chat", session, prompt);
  };

  const startNewConversation = () => {
    setSuggestionsOpen(true);
    void loadExperience("chat", session);
  };

  const selectView = (view: View) => {
    // The active destination is already on screen; nothing to reload.
    if (view === activeView) return;
    void loadExperience(view, session);
  };

  // Boot: the splash stays up until the brand has been on screen for SPLASH_MS
  // and the session (or the failure to load it) is known.
  if (bootError) {
    return <Landing error={bootError} onSignIn={() => window.location.reload()} />;
  }
  if (!splashDone || !session) return <Splash busy />;

  // Branded entry point. The button opens Cognito Managed Login, which also
  // carries the corporate sign-up link.
  if (!session.idToken) {
    return <Landing error={session.error} onSignIn={() => void signIn(session.config)} />;
  }

  const { title: pageTitle, description: pageDescription } = viewCopy[activeView];
  const current = embed?.view === activeView ? embed : undefined;
  const embedUrl = current?.url;
  const embedError = current?.error;
  const status = statusFrom(freshness, embedError);
  const userEmail = tokenEmail(session.idToken);
  const { clientName, clientLogoUrl } = session.config;

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <ClientIdentity logoUrl={clientLogoUrl} name={clientName} />
        <p className="workspace-label">Menú</p>
        <nav aria-label="Navegación principal">
          <NavButtons activeView={activeView} onSelect={selectView} />
        </nav>

        <div className="sidebar-footer">
          <div className={`sidebar-status ${status.tone}`} aria-live="polite">
            <Icon name="database" size={15} />
            <div>
              <span>{status.text}</span>
              {status.detail && <small>{status.detail}</small>}
            </div>
          </div>

          <div className="sidebar-user">
            <span className="avatar">
              <Icon name="user" size={15} />
            </span>
            <div>
              <span title={userEmail}>{userEmail ?? "Sesión activa"}</span>
              <small>Sesión iniciada</small>
            </div>
          </div>

          <button className="signout-button" onClick={() => signOut(session.config)} type="button">
            <Icon name="log-out" size={15} />
            Cerrar sesión
          </button>

          <div className="sidebar-product">
            <Wordmark size="sm" />
          </div>
        </div>
      </aside>

      <header className="mobile-header">
        <ClientIdentity compact logoUrl={clientLogoUrl} name={clientName} />
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
            <Icon name="clock" size={15} />
            {sessionWarning}
          </div>
        )}

        <header className="topbar">
          <div>
            <p className="eyebrow">{clientName ? `${clientName} · Ventas` : "Ventas"}</p>
            <h1>{pageTitle}</h1>
            <p className="subtitle">{pageDescription}</p>
          </div>
          <div className="context-badges">
            <div aria-live="polite" className={`status-badge ${status.tone}`} title={status.detail}>
              <i aria-hidden="true" className="status-dot" />
              {status.text}
            </div>
            {activeView === "chat" && (
              <button
                className="secondary-button compact"
                disabled={!embedUrl}
                onClick={startNewConversation}
                title="Las conversaciones no se guardan; cada una empieza en blanco."
                type="button"
              >
                <Icon name="message-plus" size={15} />
                Nueva conversación
              </button>
            )}
          </div>
        </header>

        {activeView === "chat" && (
          <section
            aria-labelledby="chat-invitation-title"
            className={suggestionsOpen ? "chat-invitation" : "chat-invitation collapsed"}
          >
            <span className="chat-invitation-icon">
              <Icon name="sparkles" size={18} />
            </span>
            <div className="chat-invitation-copy">
              <h2 id="chat-invitation-title">Converse con sus ventas</h2>
              {suggestionsOpen && (
                <p>
                  Pregunte en lenguaje natural o elija una sugerencia. Las conversaciones no se
                  guardan.
                </p>
              )}
            </div>
            {suggestionsOpen && (
              <div className="chat-question-examples">
                {suggestedPrompts.map((suggestion) => (
                  <button
                    className="chat-chip"
                    disabled={Boolean(embedError)}
                    key={suggestion.prompt}
                    onClick={() => askSuggestedPrompt(suggestion.prompt)}
                    type="button"
                  >
                    {suggestion.short}
                  </button>
                ))}
              </div>
            )}
            <button
              aria-expanded={suggestionsOpen}
              className="chat-invitation-toggle"
              onClick={() => setSuggestionsOpen((open) => !open)}
              type="button"
            >
              {suggestionsOpen ? "Ocultar" : "Sugerencias"}
              <Icon name={suggestionsOpen ? "chevron-up" : "chevron-down"} size={15} />
            </button>
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
                Abrir chat <Icon name="arrow-right" size={14} />
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
                  <span className="prompt-icon">
                    <Icon name={suggestion.icon} />
                  </span>
                  <span>
                    <small>{suggestion.eyebrow}</small>
                    <strong>{suggestion.title}</strong>
                  </span>
                  <span className="prompt-arrow">
                    <Icon name="arrow-right" size={16} />
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

      <footer className="mobile-product">
        <Wordmark size="sm" />
      </footer>

      <nav aria-label="Navegación móvil" className="mobile-nav">
        <NavButtons activeView={activeView} compact onSelect={selectView} />
      </nav>
    </div>
  );
}

import { useCallback, useEffect, useState } from "react";
import {
  describeAge,
  getEmbedUrl,
  getFreshness,
  type EmbedExperience,
  type FreshnessResponse,
} from "./api";
import { resolveSession, signIn, signOut, type Session } from "./auth";
import { EmbeddingFrame } from "./EmbeddingFrame";

type View = "overview" | "chat";

const viewToExperience: Record<View, EmbedExperience> = {
  overview: "dashboard",
  chat: "chat",
};

const navItems: Array<{ id: View; label: string; icon: string }> = [
  { id: "overview", label: "Pulso comercial", icon: "▦" },
  { id: "chat", label: "Preguntar a mis datos", icon: "✦" },
];

const viewCopy: Record<View, { title: string; description: string }> = {
  overview: {
    title: "Pulso de Facturación",
    description: "Indicadores y evolución de la facturación emitida.",
  },
  chat: {
    title: "Pregunta sobre tus ventas",
    description: "Conversación sobre datos comerciales verificados.",
  },
};

export default function App() {
  const [session, setSession] = useState<Session>();
  const [activeView, setActiveView] = useState<View>("overview");
  const [embedUrl, setEmbedUrl] = useState<string>();
  const [error, setError] = useState<string>();
  const [freshness, setFreshness] = useState<FreshnessResponse>();

  useEffect(() => {
    resolveSession()
      .then(setSession)
      .catch((caught: unknown) =>
        setError(caught instanceof Error ? caught.message : "No fue posible iniciar la aplicación."),
      );
  }, []);

  const loadExperience = useCallback(
    async (view: View) => {
      if (!session?.idToken) return;
      setEmbedUrl(undefined);
      setError(undefined);

      try {
        const response = await getEmbedUrl(session.config, session.idToken, viewToExperience[view]);
        setEmbedUrl(response.embedUrl);
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : "Ocurrió un error inesperado.");
      }
    },
    [session],
  );

  useEffect(() => {
    void loadExperience(activeView);
  }, [activeView, loadExperience]);

  // Poll freshness so an in-flight refresh becomes visible without reloading.
  useEffect(() => {
    if (!session?.idToken) return;

    const read = () =>
      getFreshness(session.config, session.idToken!)
        .then(setFreshness)
        .catch(() => undefined);

    void read();
    const timer = window.setInterval(read, 60_000);
    return () => window.clearInterval(timer);
  }, [session]);

  if (!session) {
    return (
      <main className="gate">
        <div className="gate-card">
          <span className="brand-mark">↗</span>
          <h1>Ventas Inteligentes</h1>
          <p>{error ?? "Verificando tu sesión…"}</p>
        </div>
      </main>
    );
  }

  if (!session.idToken) {
    return (
      <main className="gate">
        <div className="gate-card">
          <span className="brand-mark">↗</span>
          <h1>Ventas Inteligentes</h1>
          <p>Accede con tu cuenta corporativa para consultar la facturación.</p>
          {error && <p className="gate-error">{error}</p>}
          <button className="primary-button" onClick={() => void signIn(session.config)} type="button">
            Iniciar sesión
          </button>
        </div>
      </main>
    );
  }

  const { title: pageTitle, description: pageDescription } = viewCopy[activeView];

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">↗</span>
          <span>Ventas Inteligentes</span>
        </div>
        <p className="workspace-label">Espacio de trabajo</p>
        <nav aria-label="Navegación principal">
          {navItems.map((item) => (
            <button
              className={activeView === item.id ? "nav-item active" : "nav-item"}
              key={item.id}
              onClick={() => setActiveView(item.id)}
              type="button"
            >
              <span aria-hidden="true">{item.icon}</span>
              {item.label}
            </button>
          ))}
        </nav>
        <div className="sidebar-footer">
          <span title={freshness?.lastRefreshAt ?? undefined}>
            <i className={freshness?.refreshing ? "status-dot refreshing" : "status-dot"} />
            {freshness?.refreshing ? "Actualizando datos…" : describeAge(freshness?.lastRefreshAt ?? null)}
          </span>
          <small>Guatemala · GTQ</small>
          <button className="link-button" onClick={() => signOut(session.config)} type="button">
            Cerrar sesión
          </button>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div>
            <p className="eyebrow">VENTAS · GUATEMALA</p>
            <h1>{pageTitle}</h1>
            <p className="subtitle">{pageDescription}</p>
          </div>
          <div className="topbar-badge">
            <i className="status-dot" />
            Amazon Quick conectado
          </div>
        </header>

        <section className="experience-card">
          <EmbeddingFrame
            chatAgentId={session.config.quickChatAgentId}
            error={error}
            experience={viewToExperience[activeView]}
            onRetry={() => void loadExperience(activeView)}
            title={pageTitle}
            url={embedUrl}
          />
        </section>
      </main>
    </div>
  );
}

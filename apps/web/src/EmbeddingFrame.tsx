import { useEffect, useRef, useState } from "react";
import { createEmbeddingContext, type EmbeddingContext } from "amazon-quicksight-embedding-sdk";
import type { EmbedExperience } from "./api";

interface EmbeddingFrameProps {
  title: string;
  experience: EmbedExperience;
  url?: string;
  error?: string;
  /** Agente de Quick al que se fija el chat. Sin él, se usa el iframe directo de siempre. */
  chatAgentId?: string;
  onRetry: () => void;
}

export function EmbeddingFrame({ title, experience, url, error, chatAgentId, onRetry }: EmbeddingFrameProps) {
  const [mountError, setMountError] = useState<string>();
  const shownError = error ?? mountError;

  // Un error de montaje pertenece a una URL: al pedir otra, se descarta.
  useEffect(() => setMountError(undefined), [url]);

  if (shownError) {
    return (
      <section className="embed-state" aria-live="polite">
        <div className="state-icon">!</div>
        <h2>No se pudo abrir {title.toLowerCase()}</h2>
        <p>{shownError}</p>
        <button
          className="secondary-button"
          onClick={() => {
            setMountError(undefined);
            onRetry();
          }}
          type="button"
        >
          Reintentar
        </button>
      </section>
    );
  }

  if (!url) {
    return (
      <section className="embed-state" aria-live="polite">
        <div className="loading-mark" />
        <p>Cargando {title.toLowerCase()}…</p>
      </section>
    );
  }

  if (experience === "chat" && chatAgentId) {
    return <AgentChat agentId={chatAgentId} onError={setMountError} title={title} url={url} />;
  }

  return (
    <iframe
      allow="fullscreen"
      className="embedded-experience"
      referrerPolicy="strict-origin-when-cross-origin"
      src={url}
      title={title}
    />
  );
}

let contextPromise: Promise<EmbeddingContext> | undefined;

/** El SDK agrega un iframe oculto de control al body: se crea una vez por página. */
function embeddingContext(): Promise<EmbeddingContext> {
  contextPromise ??= createEmbeddingContext();
  return contextPromise;
}

interface AgentChatProps {
  title: string;
  url: string;
  agentId: string;
  onError: (message: string) => void;
}

/**
 * Chat de Quick fijado a un agente propio, ligado solo al espacio de ventas.
 * El SDK agrega estas opciones como parámetros de la URL de embedding.
 */
function AgentChat({ title, url, agentId, onError }: AgentChatProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mountedUrl = useRef<string>(undefined);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // La URL trae un código de autorización de un solo uso. StrictMode vuelve
    // a ejecutar este efecto en desarrollo sobre el mismo nodo; montarla dos
    // veces deja el chat en blanco. Solo se monta de nuevo si la URL cambió.
    if (mountedUrl.current === url) return;
    mountedUrl.current = url;
    container.replaceChildren();

    void (async () => {
      try {
        const context = await embeddingContext();
        await context.embedQuickChat(
          {
            url,
            container,
            className: "embedded-experience",
            width: "100%",
            height: "100%",
          },
          {
            agentOptions: { fixedAgentId: agentId },
            promptOptions: {
              // La conversación se queda en los datos de ventas.
              showWebSearch: false,
              allowFileAttachments: false,
              showAgentKnowledgeBoundary: false,
            },
            footerOptions: { showBrandAttribution: false },
          },
        );

        // El SDK no le pone nombre accesible al iframe.
        const iframe = container.querySelector("iframe");
        if (iframe) iframe.title = title;
      } catch (caught) {
        console.error("No se pudo montar el chat del agente", caught);
        if (mountedUrl.current === url) {
          onError("No fue posible mostrar el chat de análisis.");
        }
      }
    })();
  }, [url, agentId, title, onError]);

  return <div className="embed-container" ref={containerRef} />;
}

import { useEffect, useRef, useState } from "react";
import { createEmbeddingContext, type EmbeddingContext } from "amazon-quicksight-embedding-sdk";
import type { EmbedExperience } from "./api";

interface EmbeddingFrameProps {
  title: string;
  experience: EmbedExperience;
  url?: string;
  error?: string;
  /** Agente de Quick al que se fija el chat. Sin él, se usa el iframe directo. */
  chatAgentId?: string;
  /** Se envía una sola vez al montar el chat; no se inyecta en el DOM del iframe. */
  initialPrompt?: string;
  onChatReady?: () => void;
  onRetry: () => void;
}

export function EmbeddingFrame({
  title,
  experience,
  url,
  error,
  chatAgentId,
  initialPrompt,
  onChatReady,
  onRetry,
}: EmbeddingFrameProps) {
  // A mount error belongs to the URL that failed: a new URL clears it by itself.
  const [mountError, setMountError] = useState<{ url: string; message: string }>();
  const shownError =
    error ?? (mountError && mountError.url === url ? mountError.message : undefined);

  if (shownError) {
    return (
      <section className="embed-state" role="alert">
        <div aria-hidden="true" className="state-icon">
          !
        </div>
        <h2>No se pudo abrir {title.toLowerCase()}</h2>
        <p>{shownError}</p>
        <button className="secondary-button" onClick={onRetry} type="button">
          Reintentar
        </button>
      </section>
    );
  }

  if (!url) {
    return (
      <section className="embed-state" aria-live="polite">
        <div className="skeleton-shell" aria-hidden="true">
          <span className="skeleton-bar wide" />
          <span className="skeleton-bar" />
          <span className="skeleton-panel" />
        </div>
        <p>Cargando {title.toLowerCase()}…</p>
      </section>
    );
  }

  if (!isQuickSightUrl(url)) {
    return (
      <section className="embed-state" role="alert">
        <div aria-hidden="true" className="state-icon">
          !
        </div>
        <h2>No se pudo abrir {title.toLowerCase()}</h2>
        <p>La dirección recibida no es de Amazon Quick.</p>
      </section>
    );
  }

  if (experience === "chat" && chatAgentId) {
    return (
      <AgentChat
        agentId={chatAgentId}
        initialPrompt={initialPrompt}
        onError={(message) => setMountError({ url, message })}
        onReady={onChatReady}
        title={title}
        url={url}
      />
    );
  }

  // No `sandbox`: the QuickSight dashboard needs scripts, same-origin storage,
  // forms and popups (exports); the URL is already restricted to QuickSight over
  // HTTPS by isQuickSightUrl and the page CSP `frame-src`.
  return (
    // oxlint-disable-next-line react/iframe-missing-sandbox
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
  contextPromise ??= createEmbeddingContext().catch((error: unknown) => {
    contextPromise = undefined;
    throw error;
  });
  return contextPromise;
}

/** Only QuickSight embed URLs over HTTPS are ever put in the iframe. */
export function isQuickSightUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      (url.hostname === "quicksight.aws.amazon.com" ||
        url.hostname.endsWith(".quicksight.aws.amazon.com"))
    );
  } catch {
    return false;
  }
}

interface AgentChatProps {
  title: string;
  url: string;
  agentId: string;
  initialPrompt?: string;
  onReady?: () => void;
  onError: (message: string) => void;
}

/**
 * Chat fijado al agente de ventas. Private mode and hidden history prevent the
 * shared pilot identity from exposing one tester's conversation to another.
 */
function AgentChat({ title, url, agentId, initialPrompt, onReady, onError }: AgentChatProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mountedUrl = useRef<string>(undefined);
  // Capture only the prompt that belongs to this one-use embed URL. A state
  // update after mount must never submit it twice.
  const initialPromptRef = useRef(initialPrompt);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Each embed URL is mounted exactly once; re-runs caused by a new callback
    // identity are no-ops.
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
              initialPrompt: initialPromptRef.current,
              showInitialPromptMessage: Boolean(initialPromptRef.current),
              showWebSearch: false,
              allowFileAttachments: false,
              showAgentKnowledgeBoundary: false,
              showChatHistory: false,
              enablePrivateMode: true,
            },
            footerOptions: { showBrandAttribution: false },
          },
        );

        const iframe = container.querySelector("iframe");
        if (iframe) iframe.title = title;
        onReady?.();
      } catch (caught) {
        console.error("No se pudo montar el chat del agente", caught);
        if (mountedUrl.current === url) {
          onError("No fue posible mostrar el chat de análisis.");
        }
      }
    })();
  }, [url, agentId, title, onError, onReady]);

  return <div className="embed-container" ref={containerRef} />;
}

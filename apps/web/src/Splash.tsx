import type { ReactNode } from "react";
import { TAGLINE, Wordmark } from "./Brand";
import { Icon } from "./Icon";

/** How long the splash stays on screen at boot so the brand can be read. */
export const SPLASH_MS = 1400;

/**
 * Full-screen dark canvas used for the boot splash and the login landing.
 * Only the product brand lives here: the client's identity belongs inside the app.
 */
export function Splash({ children, busy = false }: { children?: ReactNode; busy?: boolean }) {
  return (
    <main className="splash" aria-busy={busy || undefined} aria-live="polite">
      <div className="splash-content">
        <span className="brand-mark large">
          <Icon name="trending-up" size={22} />
        </span>
        <Wordmark size="lg" />
        <p className="splash-tagline">{TAGLINE}</p>
        {children}
      </div>
      <p className="splash-foot">Analítica conversacional sobre su facturación electrónica</p>
    </main>
  );
}

/** Login landing: branded entry with a single action that opens Managed Login. */
export function Landing({ error, onSignIn }: { error?: string; onSignIn: () => void }) {
  return (
    <Splash>
      {error && (
        <p className="splash-error" role="alert">
          {error}
        </p>
      )}
      <button className="splash-button" onClick={onSignIn} type="button">
        {error ? "Volver a intentar" : "Iniciar sesión"}
        <Icon name="arrow-right" size={16} />
      </button>
      <p className="splash-hint">Acceda con su cuenta corporativa.</p>
    </Splash>
  );
}

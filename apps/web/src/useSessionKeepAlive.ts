import { useEffect, useState } from "react";
import { msUntilExpiry, REFRESH_LEAD_MS, refreshTokens, type Session, type Tokens } from "./auth";

export const SESSION_EXPIRED_MESSAGE = "Tu sesión expiró. Inicia sesión de nuevo.";
export const SESSION_ENDING_MESSAGE =
  "Tu sesión termina en menos de 5 minutos. Guarda lo que necesites; tendrás que iniciar sesión de nuevo.";

interface Options {
  session: Session | undefined;
  /** Receives renewed tokens, or the same ID token without refresh token when renewal failed. */
  onTokens: (tokens: Tokens) => void;
  onExpired: (reason: string) => void;
}

/**
 * Keeps an authenticated session alive without interrupting the user:
 *  - With a refresh token, renews the ID token five minutes before it expires.
 *  - Without one (or after a failed renewal), warns five minutes ahead and ends
 *    the session exactly at expiry.
 *
 * Returns the warning to show, or undefined when the session is healthy.
 */
export function useSessionKeepAlive({ session, onTokens, onExpired }: Options): string | undefined {
  // The warning is bound to the token it was raised for, so a renewed token
  // clears it without an extra state update.
  const [warnedToken, setWarnedToken] = useState<string>();

  const config = session?.config;
  const idToken = session?.idToken;
  const refreshToken = session?.refreshToken;

  useEffect(() => {
    if (!config || !idToken) return;

    const remaining = msUntilExpiry(idToken);
    const timers: number[] = [];
    let cancelled = false;

    if (remaining <= 0) {
      timers.push(window.setTimeout(() => onExpired(SESSION_EXPIRED_MESSAGE), 0));
    } else if (refreshToken) {
      timers.push(
        window.setTimeout(
          () => {
            refreshTokens(config, refreshToken)
              .then((tokens) => {
                if (!cancelled) onTokens(tokens);
              })
              .catch(() => {
                // Renewal failed (revoked, network, refresh token expired):
                // keep the current token and fall back to the warning path.
                if (!cancelled) onTokens({ idToken, refreshToken: undefined });
              });
          },
          Math.max(remaining - REFRESH_LEAD_MS, 0),
        ),
      );
    } else {
      timers.push(
        window.setTimeout(() => setWarnedToken(idToken), Math.max(remaining - REFRESH_LEAD_MS, 0)),
      );
      timers.push(window.setTimeout(() => onExpired(SESSION_EXPIRED_MESSAGE), remaining));
    }

    return () => {
      cancelled = true;
      timers.forEach((timer) => window.clearTimeout(timer));
    };
  }, [config, idToken, refreshToken, onTokens, onExpired]);

  return idToken && warnedToken === idToken ? SESSION_ENDING_MESSAGE : undefined;
}

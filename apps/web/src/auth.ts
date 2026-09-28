import { loadConfig, type RuntimeConfig } from "./config";

const VERIFIER_KEY = "vi.pkce.verifier";
const STATE_KEY = "vi.oauth.state";
const TOKEN_KEY = "vi.session.idToken";

const base64Url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

const randomToken = (size: number) => base64Url(crypto.getRandomValues(new Uint8Array(size)));

async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64Url(new Uint8Array(digest));
}

const redirectUri = () => `${window.location.origin}/`;

type Entry = "login" | "signup";

/**
 * Redirects to Cognito Managed Login using authorization code flow with PKCE.
 * "signup" opens the account creation page directly; both return here with a
 * code. The random state ties the callback to this browser tab (login CSRF).
 */
async function redirectToCognito(config: RuntimeConfig, entry: Entry): Promise<void> {
  const verifier = randomToken(32);
  const state = randomToken(16);
  sessionStorage.setItem(VERIFIER_KEY, verifier);
  sessionStorage.setItem(STATE_KEY, state);

  const params = new URLSearchParams({
    client_id: config.cognitoClientId,
    response_type: "code",
    scope: "openid email profile",
    redirect_uri: redirectUri(),
    state,
    code_challenge_method: "S256",
    code_challenge: await challengeFor(verifier),
  });

  const path = entry === "signup" ? "signup" : "oauth2/authorize";
  window.location.assign(`${config.cognitoDomain}/${path}?${params.toString()}`);
}

export const signIn = (config: RuntimeConfig) => redirectToCognito(config, "login");
export const signUp = (config: RuntimeConfig) => redirectToCognito(config, "signup");

/** Forgets the local token only; used when the API says the token expired. */
export function clearToken(): void {
  sessionStorage.removeItem(TOKEN_KEY);
}

export function signOut(config: RuntimeConfig): void {
  clearToken();
  const params = new URLSearchParams({
    client_id: config.cognitoClientId,
    logout_uri: redirectUri(),
  });
  window.location.assign(`${config.cognitoDomain}/logout?${params.toString()}`);
}

async function exchangeCode(config: RuntimeConfig, code: string): Promise<string> {
  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  if (!verifier) throw new Error("La sesión de autenticación expiró. Intenta iniciar sesión de nuevo.");

  const response = await fetch(`${config.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: config.cognitoClientId,
      code,
      redirect_uri: redirectUri(),
      code_verifier: verifier,
    }),
  });

  if (!response.ok) throw new Error("No fue posible completar el inicio de sesión.");

  const tokens = (await response.json()) as { id_token?: string };
  if (!tokens.id_token) throw new Error("Cognito no devolvió un token de identidad.");

  return tokens.id_token;
}

/** JWTs are base64url without padding; atob only accepts standard base64. */
function decodeJwtPayload(token: string): { exp?: number } {
  const part = token.split(".")[1] ?? "";
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
  return JSON.parse(atob(padded)) as { exp?: number };
}

/** Milliseconds until the token should be considered expired (30 s of margin). */
export function msUntilExpiry(idToken: string): number {
  try {
    const { exp } = decodeJwtPayload(idToken);
    return exp ? exp * 1000 - 30_000 - Date.now() : 0;
  } catch {
    return 0;
  }
}

export interface Session {
  config: RuntimeConfig;
  idToken?: string;
  /** Why the last sign-in attempt failed, shown next to the sign-in button. */
  error?: string;
}

/**
 * Resolves the current session: completes the Managed Login redirect when
 * present, otherwise reuses a valid token from sessionStorage. A failed
 * callback never leaves the user stuck: the URL is cleaned and the sign-in
 * button comes back with the reason.
 */
let sessionPromise: Promise<Session> | undefined;

/**
 * The authorization code is single use. React StrictMode runs effects twice in
 * development, so the callback is resolved once per page load and shared.
 */
export function resolveSession(): Promise<Session> {
  sessionPromise ??= resolveSessionOnce();
  return sessionPromise;
}

async function resolveSessionOnce(): Promise<Session> {
  const config = await loadConfig();
  const url = new URL(window.location.href);
  const code = url.searchParams.get("code");
  const returnedState = url.searchParams.get("state");
  const cognitoError = url.searchParams.get("error_description") ?? url.searchParams.get("error");

  if (code || cognitoError) {
    const expectedState = sessionStorage.getItem(STATE_KEY);
    sessionStorage.removeItem(STATE_KEY);
    // The code is single use: drop it from the URL before anything can fail,
    // so a reload never retries it.
    window.history.replaceState({}, "", url.pathname);

    if (cognitoError) {
      sessionStorage.removeItem(VERIFIER_KEY);
      return { config, error: "No fue posible iniciar sesión. Intenta de nuevo." };
    }

    try {
      if (!expectedState || returnedState !== expectedState) {
        throw new Error("La respuesta de inicio de sesión no es válida. Intenta de nuevo.");
      }
      const idToken = await exchangeCode(config, code!);
      sessionStorage.setItem(TOKEN_KEY, idToken);
      return { config, idToken };
    } catch (caught) {
      return {
        config,
        error: caught instanceof Error ? caught.message : "No fue posible completar el inicio de sesión.",
      };
    } finally {
      sessionStorage.removeItem(VERIFIER_KEY);
    }
  }

  const stored = sessionStorage.getItem(TOKEN_KEY);
  if (stored && msUntilExpiry(stored) > 0) return { config, idToken: stored };

  clearToken();
  return { config };
}

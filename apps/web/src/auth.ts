import { loadConfig, type RuntimeConfig } from "./config";
import { navigateTo } from "./navigation";

const VERIFIER_KEY = "vi.pkce.verifier";
const STATE_KEY = "vi.oauth.state";
const TOKEN_KEY = "vi.session.idToken";
const REFRESH_KEY = "vi.session.refreshToken";

/** Safety margin subtracted from `exp` so a token is never used in its last seconds. */
const EXPIRY_MARGIN_MS = 30_000;

/** How long before expiry the app renews the ID token (or warns if it cannot). */
export const REFRESH_LEAD_MS = 5 * 60_000;

const base64Url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

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
  navigateTo(`${config.cognitoDomain}/${path}?${params.toString()}`);
}

export const signIn = (config: RuntimeConfig) => redirectToCognito(config, "login");
export const signUp = (config: RuntimeConfig) => redirectToCognito(config, "signup");

export interface Tokens {
  idToken: string;
  /** Absent when Cognito did not issue one (it always does for the code flow). */
  refreshToken?: string;
}

/** Forgets the local tokens only; used when the API says the token expired. */
export function clearToken(): void {
  sessionStorage.removeItem(TOKEN_KEY);
  sessionStorage.removeItem(REFRESH_KEY);
}

function storeTokens(tokens: Tokens): void {
  sessionStorage.setItem(TOKEN_KEY, tokens.idToken);
  if (tokens.refreshToken) sessionStorage.setItem(REFRESH_KEY, tokens.refreshToken);
}

export function signOut(config: RuntimeConfig): void {
  clearToken();
  const params = new URLSearchParams({
    client_id: config.cognitoClientId,
    logout_uri: redirectUri(),
  });
  navigateTo(`${config.cognitoDomain}/logout?${params.toString()}`);
}

interface TokenResponse {
  id_token?: string;
  refresh_token?: string;
}

async function requestTokens(
  config: RuntimeConfig,
  grant: Record<string, string>,
  failureMessage: string,
): Promise<TokenResponse> {
  const response = await fetch(`${config.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: config.cognitoClientId, ...grant }),
  });

  if (!response.ok) throw new Error(failureMessage);
  return (await response.json()) as TokenResponse;
}

async function exchangeCode(config: RuntimeConfig, code: string): Promise<Tokens> {
  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  if (!verifier) {
    throw new Error("La sesión de autenticación expiró. Intenta iniciar sesión de nuevo.");
  }

  const tokens = await requestTokens(
    config,
    {
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri(),
      code_verifier: verifier,
    },
    "No fue posible completar el inicio de sesión.",
  );

  if (!tokens.id_token) throw new Error("Cognito no devolvió un token de identidad.");
  return { idToken: tokens.id_token, refreshToken: tokens.refresh_token };
}

/**
 * Renews the ID token with the refresh token so an active user is never
 * interrupted at the 60-minute mark. Cognito only returns a new refresh token
 * when rotation is enabled; otherwise the current one stays valid.
 */
export async function refreshTokens(config: RuntimeConfig, refreshToken: string): Promise<Tokens> {
  const tokens = await requestTokens(
    config,
    { grant_type: "refresh_token", refresh_token: refreshToken },
    "No fue posible renovar la sesión.",
  );

  if (!tokens.id_token) throw new Error("Cognito no devolvió un token de identidad.");
  const renewed: Tokens = {
    idToken: tokens.id_token,
    refreshToken: tokens.refresh_token ?? refreshToken,
  };
  storeTokens(renewed);
  return renewed;
}

interface IdTokenClaims {
  exp?: number;
  email?: string;
}

/** JWTs are base64url without padding; atob only accepts standard base64. */
function decodeJwtPayload(token: string): IdTokenClaims {
  const part = token.split(".")[1] ?? "";
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
  return JSON.parse(atob(padded)) as IdTokenClaims;
}

/**
 * Email claim for display only. Authorization never happens here: the API
 * re-reads the verified claim from the token that API Gateway validated.
 */
export function tokenEmail(idToken: string): string | undefined {
  try {
    const { email } = decodeJwtPayload(idToken);
    return typeof email === "string" && email ? email : undefined;
  } catch {
    return undefined;
  }
}

/** Milliseconds until the token should be considered expired (30 s of margin). */
export function msUntilExpiry(idToken: string, now: number = Date.now()): number {
  try {
    const { exp } = decodeJwtPayload(idToken);
    return exp ? exp * 1000 - EXPIRY_MARGIN_MS - now : 0;
  } catch {
    return 0;
  }
}

export interface Session {
  config: RuntimeConfig;
  idToken?: string;
  refreshToken?: string;
  /** Why the last sign-in attempt failed, shown next to the sign-in button. */
  error?: string;
}

let sessionPromise: Promise<Session> | undefined;

/**
 * Resolves the current session: completes the Managed Login redirect when
 * present, otherwise reuses valid tokens from sessionStorage. A failed
 * callback never leaves the user stuck: the URL is cleaned and the sign-in
 * button comes back with the reason.
 *
 * The authorization code is single use. React StrictMode runs effects twice in
 * development, so the callback is resolved once per page load and shared.
 */
export function resolveSession(): Promise<Session> {
  sessionPromise ??= resolveSessionOnce();
  return sessionPromise;
}

/** Test hook: forget the memoized session so the next call resolves again. */
export function resetSessionCache(): void {
  sessionPromise = undefined;
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

    if (cognitoError || !code) {
      sessionStorage.removeItem(VERIFIER_KEY);
      return { config, error: "No fue posible iniciar sesión. Intenta de nuevo." };
    }

    try {
      if (!expectedState || returnedState !== expectedState) {
        throw new Error("La respuesta de inicio de sesión no es válida. Intenta de nuevo.");
      }
      const tokens = await exchangeCode(config, code);
      storeTokens(tokens);
      return { config, ...tokens };
    } catch (caught) {
      return {
        config,
        error:
          caught instanceof Error
            ? caught.message
            : "No fue posible completar el inicio de sesión.",
      };
    } finally {
      sessionStorage.removeItem(VERIFIER_KEY);
    }
  }

  const storedId = sessionStorage.getItem(TOKEN_KEY);
  const storedRefresh = sessionStorage.getItem(REFRESH_KEY) ?? undefined;

  if (storedId && msUntilExpiry(storedId) > 0) {
    return { config, idToken: storedId, refreshToken: storedRefresh };
  }

  // Expired ID token but a refresh token in hand: renew silently instead of
  // sending the person back through Managed Login.
  if (storedRefresh) {
    try {
      return { config, ...(await refreshTokens(config, storedRefresh)) };
    } catch {
      // Fall through to a clean sign-in.
    }
  }

  clearToken();
  return { config };
}

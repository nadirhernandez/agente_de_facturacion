import { loadConfig, type RuntimeConfig } from "./config";

const VERIFIER_KEY = "vi.pkce.verifier";
const TOKEN_KEY = "vi.session.idToken";

const base64Url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

const randomVerifier = () => base64Url(crypto.getRandomValues(new Uint8Array(32)));

async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64Url(new Uint8Array(digest));
}

const redirectUri = () => `${window.location.origin}/`;

/** Redirects to the Cognito Hosted UI using authorization code flow with PKCE. */
export async function signIn(config: RuntimeConfig): Promise<void> {
  const verifier = randomVerifier();
  sessionStorage.setItem(VERIFIER_KEY, verifier);

  const params = new URLSearchParams({
    client_id: config.cognitoClientId,
    response_type: "code",
    scope: "openid email profile",
    redirect_uri: redirectUri(),
    code_challenge_method: "S256",
    code_challenge: await challengeFor(verifier),
  });

  window.location.assign(`${config.cognitoDomain}/oauth2/authorize?${params.toString()}`);
}

export function signOut(config: RuntimeConfig): void {
  sessionStorage.removeItem(TOKEN_KEY);
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

  sessionStorage.removeItem(VERIFIER_KEY);
  return tokens.id_token;
}

const isExpired = (idToken: string): boolean => {
  try {
    const payload = JSON.parse(atob(idToken.split(".")[1])) as { exp?: number };
    return !payload.exp || payload.exp * 1000 <= Date.now() + 30_000;
  } catch {
    return true;
  }
};

export interface Session {
  config: RuntimeConfig;
  idToken?: string;
}

/**
 * Resolves the current session: completes the Hosted UI redirect when present,
 * otherwise reuses a valid token from sessionStorage.
 */
export async function resolveSession(): Promise<Session> {
  const config = await loadConfig();
  const url = new URL(window.location.href);
  const code = url.searchParams.get("code");

  if (code) {
    const idToken = await exchangeCode(config, code);
    sessionStorage.setItem(TOKEN_KEY, idToken);
    url.searchParams.delete("code");
    url.searchParams.delete("state");
    window.history.replaceState({}, "", url.pathname);
    return { config, idToken };
  }

  const stored = sessionStorage.getItem(TOKEN_KEY);
  if (stored && !isExpired(stored)) return { config, idToken: stored };

  sessionStorage.removeItem(TOKEN_KEY);
  return { config };
}

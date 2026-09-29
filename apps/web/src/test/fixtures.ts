import type { RuntimeConfig } from "../config";

export const config: RuntimeConfig = {
  apiBaseUrl: "https://api.example.com",
  cognitoDomain: "https://auth.example.com",
  cognitoClientId: "client-123",
  region: "us-east-1",
  quickChatAgentId: "agent-1",
};

const base64Url = (value: string) =>
  btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Unsigned JWT with the given payload; the app only reads `exp`. */
export function fakeJwt(payload: Record<string, unknown>): string {
  return `${base64Url(JSON.stringify({ alg: "none" }))}.${base64Url(JSON.stringify(payload))}.sig`;
}

/** Token expiring `seconds` from `now`. */
export const tokenExpiringIn = (seconds: number, now = Date.now()) =>
  fakeJwt({ exp: Math.floor(now / 1000) + seconds, email: "ana@example.com" });

export function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
    ...init,
  });
}

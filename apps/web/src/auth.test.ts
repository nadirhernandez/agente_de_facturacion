import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  clearToken,
  msUntilExpiry,
  refreshTokens,
  resetSessionCache,
  resolveSession,
  signIn,
  signOut,
  tokenEmail,
} from "./auth";
import { config, fakeJwt, jsonResponse, tokenExpiringIn } from "./test/fixtures";

const navigation = vi.hoisted(() => ({ navigateTo: vi.fn<(url: string) => void>() }));
vi.mock("./navigation", () => navigation);

vi.mock("./config", () => ({
  loadConfig: vi.fn(async () => ({
    apiBaseUrl: "https://api.example.com",
    cognitoDomain: "https://auth.example.com",
    cognitoClientId: "client-123",
    region: "us-east-1",
  })),
}));

const setLocation = (search: string) => {
  window.history.replaceState({}, "", `/${search}`);
};

beforeEach(() => {
  resetSessionCache();
  setLocation("");
});

afterEach(() => vi.restoreAllMocks());

describe("msUntilExpiry", () => {
  it("subtracts a 30 second safety margin", () => {
    const now = 1_700_000_000_000;
    expect(msUntilExpiry(fakeJwt({ exp: now / 1000 + 600 }), now)).toBe(600_000 - 30_000);
  });

  it("treats malformed tokens as expired", () => {
    expect(msUntilExpiry("not-a-jwt")).toBe(0);
    expect(msUntilExpiry(fakeJwt({}))).toBe(0);
  });
});

describe("signIn", () => {
  it("redirects to Managed Login with PKCE and a random state", async () => {
    await signIn(config);

    expect(navigation.navigateTo).toHaveBeenCalledTimes(1);
    const target = new URL(navigation.navigateTo.mock.calls[0]![0]);
    expect(target.origin + target.pathname).toBe("https://auth.example.com/oauth2/authorize");
    expect(target.searchParams.get("response_type")).toBe("code");
    expect(target.searchParams.get("code_challenge_method")).toBe("S256");
    expect(target.searchParams.get("client_id")).toBe("client-123");
    expect(target.searchParams.get("redirect_uri")).toBe(`${window.location.origin}/`);
    expect(target.searchParams.get("state")).toBe(sessionStorage.getItem("vi.oauth.state"));
    expect(sessionStorage.getItem("vi.pkce.verifier")).toBeTruthy();
    expect(target.searchParams.get("code_challenge")).not.toBe(
      sessionStorage.getItem("vi.pkce.verifier"),
    );
  });
});

describe("resolveSession", () => {
  it("returns no token when nothing is stored", async () => {
    await expect(resolveSession()).resolves.toEqual({
      config: expect.objectContaining({ cognitoClientId: "client-123" }),
    });
  });

  it("reuses a stored, still valid token", async () => {
    const idToken = tokenExpiringIn(3600);
    sessionStorage.setItem("vi.session.idToken", idToken);
    sessionStorage.setItem("vi.session.refreshToken", "rt-1");

    await expect(resolveSession()).resolves.toMatchObject({ idToken, refreshToken: "rt-1" });
  });

  it("renews silently when the stored token expired but a refresh token exists", async () => {
    const renewed = tokenExpiringIn(3600);
    sessionStorage.setItem("vi.session.idToken", tokenExpiringIn(-60));
    sessionStorage.setItem("vi.session.refreshToken", "rt-1");
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse({ id_token: renewed }));

    await expect(resolveSession()).resolves.toMatchObject({
      idToken: renewed,
      refreshToken: "rt-1",
    });
    const body = fetchMock.mock.calls[0]![1]!.body as URLSearchParams;
    expect(body.get("grant_type")).toBe("refresh_token");
    expect(sessionStorage.getItem("vi.session.idToken")).toBe(renewed);
  });

  it("drops everything when the renewal fails", async () => {
    sessionStorage.setItem("vi.session.idToken", tokenExpiringIn(-60));
    sessionStorage.setItem("vi.session.refreshToken", "rt-1");
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 400 }));

    await expect(resolveSession()).resolves.toEqual({ config: expect.anything() });
    expect(sessionStorage.getItem("vi.session.refreshToken")).toBeNull();
  });

  it("exchanges the authorization code once, checks the state and cleans the URL", async () => {
    const idToken = tokenExpiringIn(3600);
    sessionStorage.setItem("vi.pkce.verifier", "verifier-1");
    sessionStorage.setItem("vi.oauth.state", "state-1");
    setLocation("?code=abc&state=state-1");
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse({ id_token: idToken, refresh_token: "rt-2" }));

    const session = await resolveSession();

    expect(session).toMatchObject({ idToken, refreshToken: "rt-2" });
    expect(window.location.search).toBe("");
    const body = fetchMock.mock.calls[0]![1]!.body as URLSearchParams;
    expect(body.get("grant_type")).toBe("authorization_code");
    expect(body.get("code")).toBe("abc");
    expect(body.get("code_verifier")).toBe("verifier-1");
    expect(sessionStorage.getItem("vi.pkce.verifier")).toBeNull();
    expect(sessionStorage.getItem("vi.oauth.state")).toBeNull();
    expect(sessionStorage.getItem("vi.session.refreshToken")).toBe("rt-2");

    // Memoized: a second call (StrictMode) must not exchange the code again.
    await resolveSession();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("rejects a callback whose state does not match (login CSRF)", async () => {
    sessionStorage.setItem("vi.pkce.verifier", "verifier-1");
    sessionStorage.setItem("vi.oauth.state", "state-1");
    setLocation("?code=abc&state=forged");
    const fetchMock = vi.spyOn(globalThis, "fetch");

    const session = await resolveSession();

    expect(session.idToken).toBeUndefined();
    expect(session.error).toMatch(/no es válida/);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(window.location.search).toBe("");
  });

  it("reports a Cognito error without retrying", async () => {
    setLocation("?error=access_denied&error_description=User+cancelled");
    const session = await resolveSession();
    expect(session.error).toBe("No fue posible iniciar sesión. Intenta de nuevo.");
    expect(window.location.search).toBe("");
  });
});

describe("signOut", () => {
  it("forgets both tokens and redirects to Cognito logout", () => {
    sessionStorage.setItem("vi.session.idToken", "id");
    sessionStorage.setItem("vi.session.refreshToken", "rt");

    signOut(config);

    expect(sessionStorage.getItem("vi.session.idToken")).toBeNull();
    expect(sessionStorage.getItem("vi.session.refreshToken")).toBeNull();
    const target = new URL(navigation.navigateTo.mock.calls.at(-1)![0]);
    expect(target.pathname).toBe("/logout");
    expect(target.searchParams.get("logout_uri")).toBe(`${window.location.origin}/`);
  });
});

describe("refreshTokens / clearToken", () => {
  it("keeps the previous refresh token when Cognito does not rotate it", async () => {
    const renewed = tokenExpiringIn(3600);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse({ id_token: renewed }));

    await expect(refreshTokens(config, "rt-1")).resolves.toEqual({
      idToken: renewed,
      refreshToken: "rt-1",
    });
    expect(sessionStorage.getItem("vi.session.refreshToken")).toBe("rt-1");

    clearToken();
    expect(sessionStorage.getItem("vi.session.idToken")).toBeNull();
    expect(sessionStorage.getItem("vi.session.refreshToken")).toBeNull();
  });

  it("throws when Cognito rejects the refresh token", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 400 }));
    await expect(refreshTokens(config, "rt-1")).rejects.toThrow(
      "No fue posible renovar la sesión.",
    );
  });
});

describe("tokenEmail", () => {
  it("reads the email claim for display", () => {
    expect(tokenEmail(fakeJwt({ email: "ana@example.com" }))).toBe("ana@example.com");
  });

  it("returns undefined for tokens without a usable claim", () => {
    expect(tokenEmail(fakeJwt({}))).toBeUndefined();
    expect(tokenEmail(fakeJwt({ email: 42 }))).toBeUndefined();
    expect(tokenEmail("garbage")).toBeUndefined();
  });
});

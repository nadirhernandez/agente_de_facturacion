import { afterEach, describe, expect, it, vi } from "vitest";
import { describeAge, getEmbedUrl, getFreshness, SessionExpiredError } from "./api";
import { config, jsonResponse } from "./test/fixtures";

afterEach(() => vi.restoreAllMocks());

describe("getEmbedUrl", () => {
  it("sends the bearer token and the experience", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(
        jsonResponse({ embedUrl: "https://q/embed", expiresAt: "2026-01-01T00:00:00Z" }),
      );

    const result = await getEmbedUrl(config, "id-token", "chat");

    expect(result.embedUrl).toBe("https://q/embed");
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("https://api.example.com/embed?experience=chat");
    expect(init?.headers).toEqual({ authorization: "Bearer id-token" });
  });

  it("maps 401 to SessionExpiredError", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 401 }));
    await expect(getEmbedUrl(config, "t", "dashboard")).rejects.toBeInstanceOf(SessionExpiredError);
  });

  it("surfaces the API message on 403", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({ message: "Tu cuenta aún no tiene acceso." }, { status: 403 }),
    );
    await expect(getEmbedUrl(config, "t", "dashboard")).rejects.toThrow(
      "Tu cuenta aún no tiene acceso.",
    );
  });

  it("uses a generic message for other failures", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("boom", { status: 500 }));
    await expect(getEmbedUrl(config, "t", "dashboard")).rejects.toThrow(
      "No fue posible iniciar la experiencia de análisis.",
    );
  });
});

describe("getFreshness", () => {
  it("returns the parsed status payload", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({ lastRefreshAt: "2026-09-28T10:00:00Z", refreshing: false, datasets: [] }),
    );
    await expect(getFreshness(config, "t")).resolves.toMatchObject({ refreshing: false });
  });

  it("maps 401 to SessionExpiredError", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 401 }));
    await expect(getFreshness(config, "t")).rejects.toBeInstanceOf(SessionExpiredError);
  });
});

describe("describeAge", () => {
  const now = new Date("2026-09-28T12:00:00Z").getTime();
  const ago = (ms: number) => new Date(now - ms).toISOString();

  it("describes the age in Spanish", () => {
    vi.spyOn(Date, "now").mockReturnValue(now);
    expect(describeAge(null)).toBe("sin registro de actualización");
    expect(describeAge(ago(10_000))).toBe("actualizado hace un momento");
    expect(describeAge(ago(5 * 60_000))).toBe("actualizado hace 5 min");
    expect(describeAge(ago(3 * 3_600_000))).toBe("actualizado hace 3 h");
    expect(describeAge(ago(30 * 3_600_000))).toBe("actualizado ayer");
    expect(describeAge(ago(72 * 3_600_000))).toBe("actualizado hace 3 días");
  });
});

import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Session, Tokens } from "./auth";
import {
  SESSION_ENDING_MESSAGE,
  SESSION_EXPIRED_MESSAGE,
  useSessionKeepAlive,
} from "./useSessionKeepAlive";
import { config, jsonResponse, tokenExpiringIn } from "./test/fixtures";

const MINUTE = 60_000;

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-09-28T12:00:00Z"));
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

function setup(session: Session) {
  const onTokens = vi.fn<(tokens: Tokens) => void>();
  const onExpired = vi.fn<(reason: string) => void>();
  const hook = renderHook(
    ({ current }: { current: Session }) =>
      useSessionKeepAlive({ session: current, onTokens, onExpired }),
    { initialProps: { current: session } },
  );
  return { ...hook, onTokens, onExpired };
}

describe("useSessionKeepAlive", () => {
  it("renews the ID token five minutes before expiry when a refresh token exists", async () => {
    const renewed = tokenExpiringIn(60 * 60);
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse({ id_token: renewed }));
    const { result, onTokens, onExpired } = setup({
      config,
      idToken: tokenExpiringIn(10 * 60),
      refreshToken: "rt-1",
    });

    // 10 min token − 30 s margin − 5 min lead = renew after 4.5 min.
    await act(() => vi.advanceTimersByTimeAsync(4 * MINUTE));
    expect(fetchMock).not.toHaveBeenCalled();

    await act(() => vi.advanceTimersByTimeAsync(1 * MINUTE));
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(onTokens).toHaveBeenCalledWith({ idToken: renewed, refreshToken: "rt-1" });
    expect(onExpired).not.toHaveBeenCalled();
    expect(result.current).toBeUndefined();
  });

  it("falls back to warning and expiry when the renewal fails", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 400 }));
    const idToken = tokenExpiringIn((10 * MINUTE) / 1000);
    const { result, rerender, onTokens, onExpired } = setup({
      config,
      idToken,
      refreshToken: "rt-1",
    });

    await act(() => vi.advanceTimersByTimeAsync(5 * MINUTE));
    expect(onTokens).toHaveBeenCalledWith({ idToken, refreshToken: undefined });

    // The app applies the callback: same token, no refresh token.
    rerender({ current: { config, idToken } });
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(result.current).toBe(SESSION_ENDING_MESSAGE);

    await act(() => vi.advanceTimersByTimeAsync(5 * MINUTE));
    expect(onExpired).toHaveBeenCalledWith(SESSION_EXPIRED_MESSAGE);
  });

  it("warns five minutes ahead and ends the session at expiry without a refresh token", async () => {
    const { result, onExpired } = setup({ config, idToken: tokenExpiringIn(8 * 60) });

    expect(result.current).toBeUndefined();
    await act(() => vi.advanceTimersByTimeAsync(2.5 * MINUTE));
    expect(result.current).toBe(SESSION_ENDING_MESSAGE);
    expect(onExpired).not.toHaveBeenCalled();

    await act(() => vi.advanceTimersByTimeAsync(5 * MINUTE));
    expect(onExpired).toHaveBeenCalledWith(SESSION_EXPIRED_MESSAGE);
  });

  it("clears the warning once a new token arrives", async () => {
    const { result, rerender } = setup({ config, idToken: tokenExpiringIn(6 * 60) });
    await act(() => vi.advanceTimersByTimeAsync(1 * MINUTE));
    expect(result.current).toBe(SESSION_ENDING_MESSAGE);

    rerender({ current: { config, idToken: tokenExpiringIn(60 * 60), refreshToken: "rt" } });
    expect(result.current).toBeUndefined();
  });

  it("ends an already expired session immediately", async () => {
    const { onExpired } = setup({ config, idToken: tokenExpiringIn(-10) });
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(onExpired).toHaveBeenCalledWith(SESSION_EXPIRED_MESSAGE);
  });

  it("does nothing without a session", () => {
    const { result, onExpired } = setup({ config });
    expect(result.current).toBeUndefined();
    expect(onExpired).not.toHaveBeenCalled();
  });
});

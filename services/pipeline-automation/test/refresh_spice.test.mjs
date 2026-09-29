import { beforeEach, describe, expect, it } from "vitest";
import { businessDate, chooseRefreshType, ingestionIdFor } from "../src/refresh_spice.mjs";

beforeEach(() => {
  process.env.LOOKBACK_DAYS = "10";
});

describe("businessDate", () => {
  it("uses Guatemala civil time (UTC-06:00)", () => {
    // 03:00 UTC on the 2nd is still the 1st in Guatemala.
    expect(businessDate(new Date("2026-10-02T03:00:00Z"))).toBe("2026-10-01");
    expect(businessDate(new Date("2026-10-02T06:00:00Z"))).toBe("2026-10-02");
  });
});

describe("chooseRefreshType", () => {
  const now = new Date("2026-09-28T18:00:00Z"); // 2026-09-28 in Guatemala

  it("falls back to FULL when the event carries no Glue run", async () => {
    await expect(chooseRefreshType(undefined, now)).resolves.toMatchObject({
      type: "FULL_REFRESH",
    });
  });

  it("falls back to FULL when the run loaded no files", async () => {
    const result = await chooseRefreshType("jr_abc", now, async () => undefined);
    expect(result).toMatchObject({ type: "FULL_REFRESH", reason: "run recorded no files" });
  });

  it("chooses INCREMENTAL when the oldest date is inside the safe window", async () => {
    // LOOKBACK_DAYS 10 minus 2 days of margin: cutoff is 2026-09-20.
    const result = await chooseRefreshType("jr_abc", now, async () => "2026-09-20");
    expect(result).toMatchObject({ type: "INCREMENTAL_REFRESH", oldest: "2026-09-20" });
  });

  it("chooses FULL when the load touched dates older than the window", async () => {
    const result = await chooseRefreshType("jr_abc", now, async () => "2026-09-19");
    expect(result).toMatchObject({ type: "FULL_REFRESH", oldest: "2026-09-19" });
    expect(result.reason).toContain("older than 2026-09-20");
  });

  it("refuses a LOOKBACK_DAYS below 3", async () => {
    process.env.LOOKBACK_DAYS = "2";
    await expect(chooseRefreshType("jr_abc", now, async () => "2026-09-28")).rejects.toThrow(
      "LOOKBACK_DAYS must be an integer >= 3",
    );
  });
});

describe("ingestionIdFor", () => {
  it("is deterministic per run, dataset and type", () => {
    const first = ingestionIdFor("ds-1", "INCREMENTAL_REFRESH", "jr_abc");
    expect(first).toBe("auto-jr_abc-inc-ds-1");
    expect(ingestionIdFor("ds-1", "INCREMENTAL_REFRESH", "jr_abc")).toBe(first);
    expect(ingestionIdFor("ds-1", "FULL_REFRESH", "jr_abc")).toBe("auto-jr_abc-full-ds-1");
  });

  it("only emits characters QuickSight accepts and caps the length", () => {
    const id = ingestionIdFor("a".repeat(200), "FULL_REFRESH", "x y/z");
    expect(id).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(id.length).toBeLessThanOrEqual(128);
    expect(id.startsWith("auto-x-y-z-full-")).toBe(true);
  });
});

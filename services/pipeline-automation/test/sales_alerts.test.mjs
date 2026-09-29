import { describe, expect, it } from "vitest";
import { buildQuery, comparisonMonths } from "../src/sales_alerts.mjs";

describe("comparisonMonths", () => {
  it("compares the last two complete months by Guatemala date", () => {
    // 2 October 2026, 08:00 UTC = 2 October 02:00 in Guatemala.
    expect(comparisonMonths(new Date("2026-10-02T08:00:00Z"))).toEqual({
      mes: "2026-09",
      mesActual: "2026-09-01",
      mesPrevio: "2026-08-01",
      hasta: "2026-10-01",
    });
  });

  it("stays in the previous month right after UTC midnight on the 1st", () => {
    // 1 October 03:00 UTC is still 30 September in Guatemala.
    expect(comparisonMonths(new Date("2026-10-01T03:00:00Z"))).toMatchObject({
      mes: "2026-08",
      hasta: "2026-09-01",
    });
  });

  it("rolls over the year", () => {
    expect(comparisonMonths(new Date("2027-01-02T12:00:00Z"))).toEqual({
      mes: "2026-12",
      mesActual: "2026-12-01",
      mesPrevio: "2026-11-01",
      hasta: "2027-01-01",
    });
  });
});

describe("buildQuery", () => {
  const months = { mesActual: "2026-09-01", mesPrevio: "2026-08-01", hasta: "2026-10-01" };

  it("builds a query bounded to the two months on the partition column", () => {
    const sql = buildQuery("ventas_dev", months);
    expect(sql).toContain("FROM ventas_dev.vw_ventas_comerciales");
    expect(sql).toContain("WHERE fecha >= DATE '2026-08-01' AND fecha < DATE '2026-10-01'");
    expect(sql).toContain("CASE WHEN fecha >= DATE '2026-09-01'");
  });

  it("rejects a database name that could inject SQL", () => {
    expect(() => buildQuery("ventas; DROP TABLE x", months)).toThrow("Invalid ATHENA_DATABASE");
    expect(() => buildQuery("Ventas", months)).toThrow("Invalid ATHENA_DATABASE");
  });

  it("rejects date bounds that are not ISO dates", () => {
    expect(() => buildQuery("ventas", { ...months, hasta: "2026-10-01' OR 1=1 --" })).toThrow(
      "Invalid date bound",
    );
  });
});

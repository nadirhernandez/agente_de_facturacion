import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { loadStatements, modelVariables, render } from "../src/deploy_views.mjs";

const REPO_SQL_MODEL = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../sql/model",
);

describe("modelVariables", () => {
  it("derives warehouse and bucket from the environment", () => {
    expect(
      modelVariables({ GLUE_DATABASE: "ventas_dev", WAREHOUSE_PATH: "s3://my-bucket/warehouse/" }),
    ).toEqual({
      db: "ventas_dev",
      warehouse: "s3://my-bucket/warehouse",
      bucket: "s3://my-bucket",
    });
  });

  it("rejects database names and paths that could break the DDL", () => {
    expect(() =>
      modelVariables({ GLUE_DATABASE: "ventas dev", WAREHOUSE_PATH: "s3://b/w" }),
    ).toThrow("Invalid GLUE_DATABASE");
    expect(() => modelVariables({ GLUE_DATABASE: "ventas", WAREHOUSE_PATH: "s3://b/w'" })).toThrow(
      "Invalid WAREHOUSE_PATH",
    );
    expect(() =>
      modelVariables({ GLUE_DATABASE: "ventas", WAREHOUSE_PATH: "https://b/w" }),
    ).toThrow("Invalid WAREHOUSE_PATH");
    expect(() => modelVariables({ GLUE_DATABASE: "ventas" })).toThrow("Invalid WAREHOUSE_PATH");
  });
});

describe("render", () => {
  const variables = { db: "ventas", warehouse: "s3://b/w", bucket: "s3://b" };

  it("substitutes known markers, strips comment lines and the trailing semicolon", () => {
    const sql = [
      "-- header comment",
      "CREATE TABLE ${db}.t (",
      "  id int",
      ") LOCATION '${warehouse}/t';",
      "",
    ].join("\n");
    expect(render(sql, variables)).toBe(
      "CREATE TABLE ventas.t (\n  id int\n) LOCATION 's3://b/w/t'",
    );
  });

  it("refuses SQL with an unknown marker", () => {
    expect(() => render("SELECT '${nope}'", variables)).toThrow("Unknown marker ${nope}");
  });
});

describe("loadStatements", () => {
  let dir;

  beforeAll(async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), "views-"));
    await mkdir(path.join(dir, "views"));
    await writeFile(
      path.join(dir, "views", "20_second.sql"),
      "CREATE OR REPLACE VIEW ${db}.second AS SELECT 2;",
    );
    await writeFile(
      path.join(dir, "views", "10_first.sql"),
      "CREATE OR REPLACE VIEW ${db}.first AS SELECT 1;",
    );
    await writeFile(path.join(dir, "views", "README.md"), "ignored");
    await mkdir(path.join(dir, "bad"));
    await writeFile(path.join(dir, "bad", "first.sql"), "SELECT 1");
    await mkdir(path.join(dir, "empty"));
  });

  afterAll(() => rm(dir, { recursive: true, force: true }));

  it("loads *.sql in name order and derives the object name from the file", async () => {
    const statements = await loadStatements(dir, "views", { db: "ventas" });
    expect(statements.map((s) => s.name)).toEqual(["first", "second"]);
    expect(statements[0].sql).toBe("CREATE OR REPLACE VIEW ventas.first AS SELECT 1");
  });

  it("requires the NN_<name>.sql convention", async () => {
    await expect(loadStatements(dir, "bad", {})).rejects.toThrow(
      "SQL file must be named NN_<name>.sql",
    );
  });

  it("fails when a folder has no SQL", async () => {
    await expect(loadStatements(dir, "empty", {})).rejects.toThrow("No SQL files in");
  });

  it("renders every file of the real model without unknown markers", async () => {
    const variables = {
      db: "ventas_dev",
      warehouse: "s3://bucket/warehouse",
      bucket: "s3://bucket",
    };
    const tables = await loadStatements(REPO_SQL_MODEL, "tables", variables);
    const views = await loadStatements(REPO_SQL_MODEL, "views", variables);
    expect(tables.length).toBeGreaterThan(0);
    expect(views.length).toBeGreaterThan(0);
    for (const { sql } of [...tables, ...views]) {
      expect(sql).not.toMatch(/\$\{/);
      expect(sql.endsWith(";")).toBe(false);
    }
  });
});

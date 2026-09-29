import { defineConfig } from "vitest/config";

/**
 * Two projects share one runner:
 *  - web: React components and browser modules under jsdom.
 *  - services: Lambda handlers (plain ESM) under Node.
 * Test files live next to the code (`*.test.ts[x]`) or in `services/<svc>/test`,
 * never in `services/<svc>/src`, because scripts/build_lambda_bundle.sh copies
 * every `src/*.mjs` into the deployment bundle.
 */
export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "web",
          root: "apps/web",
          environment: "jsdom",
          include: ["src/**/*.test.{ts,tsx}"],
          setupFiles: ["src/test/setup.ts"],
        },
      },
      {
        test: {
          name: "services",
          environment: "node",
          include: ["services/*/test/**/*.test.mjs"],
        },
      },
    ],
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      include: ["apps/web/src/**/*.{ts,tsx}", "services/*/src/**/*.mjs"],
      exclude: [
        "**/*.test.*",
        "apps/web/src/test/**",
        "apps/web/src/main.tsx",
        "apps/web/src/vite-env.d.ts",
      ],
    },
  },
});

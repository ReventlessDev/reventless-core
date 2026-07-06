const path = require("path");

// PG_URL integration config — opt-in, run via `pnpm run test:integration:pg`
// (which boots a Postgres sidecar and exports PG_URL first). Separate from the
// DynamoDB integration config (jest.integration.config.js) because these suites
// need Postgres, not DynamoDB Local, and — unlike the DynamoDB suites, which
// isolate by unique table prefix — they share one database and truncateAll, so
// they MUST run serially (`maxWorkers: 1`) to avoid cross-suite contention.
//
// The suites live under tests/ (not tests/integration/) and self-skip when
// PG_URL is unset, so they also appear — and skip — in the default unit run's
// ignore list is what keeps them OUT of the parallel default project.
const setupFile = path.resolve(__dirname, "jest.setup.cjs");

/** @type {import('jest').Config} */
module.exports = {
  rootDir: __dirname,
  reporters: ["<rootDir>/jest.reporter.js"],
  setupFiles: [setupFile],
  testMatch: [
    "<rootDir>/reventless/reventless-aws/tests/Pg*IntegrationTest.res.mjs",
  ],
  moduleFileExtensions: ["js", "mjs", "cjs"],
  // Mirror the default reventless-aws project's shims (paths rebased to this
  // repo-root rootDir): a transitive import in these suites pulls the deploy-time
  // graph, which references @npmcli/arborist + spdx-*. Without these the real
  // modules throw during ESM collection and the suite silently registers 0 tests.
  moduleNameMapper: {
    "^@npmcli/arborist$": "<rootDir>/reventless/reventless-aws/__mocks__/emptyModule.js",
    "^spdx-license-ids$": "<rootDir>/node_modules/spdx-license-ids/index.json",
    "^spdx-license-ids/deprecated$": "<rootDir>/node_modules/spdx-license-ids/deprecated.json",
    "^spdx-exceptions$": "<rootDir>/node_modules/spdx-exceptions/index.json",
  },
  // One database shared across suites + truncateAll ⇒ serial is required.
  maxWorkers: 1,
  testTimeout: 30000,
};

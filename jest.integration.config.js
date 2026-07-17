const path = require("path");

// Integration test config — opt-in, run via `pnpm run test:integration` (which
// boots a DynamoDB Local sidecar first). NOT part of the default `pnpm test`
// project list, so unit runs stay fast and engine-free.
const setupFile = path.resolve(__dirname, "jest.setup.cjs");
const integrationSetup = path.resolve(__dirname, "jest.integration.setup.cjs");

/** @type {import('jest').Config} */
module.exports = {
  rootDir: __dirname,
  reporters: ["<rootDir>/jest.reporter.js"],
  // integrationSetup must run first: it points the AWS SDK at DynamoDB Local
  // before any client singleton is constructed.
  setupFiles: [integrationSetup, setupFile],
  testMatch: [
    "<rootDir>/reventless/aws/tests/integration/**/*Test.res.mjs",
  ],
  moduleFileExtensions: ["js", "mjs", "cjs"],
  testTimeout: 30000,
};

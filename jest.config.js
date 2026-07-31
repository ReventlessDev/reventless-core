const path = require("path");

const setupFile = path.resolve(__dirname, "jest.setup.cjs");
// node:sqlite cannot be resolved by Jest 27's CJS resolver. The bridge .mjs
// pulls the real module off globalThis (populated by sqliteGlobal setup) so
// any project that transitively loads reventless-local still resolves it.
const sqliteBridge = path.resolve(
  __dirname,
  "reventless/local/__mocks__/nodeSqlite.mjs",
);
const sqliteGlobalSetup = path.resolve(
  __dirname,
  "reventless/local/tests/setup/sqliteGlobal.cjs",
);

/** @type {import('jest').Config} */
module.exports = {
  reporters: ["<rootDir>/jest.reporter.js"],
  watchPathIgnorePatterns: ["<rootDir>/.+/lib/bs/"],
  projects: [
    {
      displayName: "rescript-pulumi-aws",
      rootDir: "./rescript/pulumi-aws",
      testMatch: ["<rootDir>/tests/**/*Test.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
      moduleNameMapper: {
        "^@aws-appsync/utils$": "<rootDir>/tests/__mocks__/appsync-utils.mjs",
      },
    },
    {
      displayName: "reventless-aws",
      rootDir: "./reventless/aws",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      // Integration suites are owned by `test:integration` / `test:integration:pg`
      // (they need live AWS / Postgres) — excluded here so they don't double-run.
      testPathIgnorePatterns: [
        "/node_modules/",
        "<rootDir>/tests/integration/",
        "Pg.*IntegrationTest\\.res\\.mjs$",
      ],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile],
      moduleNameMapper: {
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "reventless-core",
      rootDir: "./reventless/core",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      testPathIgnorePatterns: [
        "/node_modules/",
        "<rootDir>/tests/AsyncTest.res.mjs",
      ],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "reventless-gwt",
      rootDir: "./reventless/gwt",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "reventless-local",
      rootDir: "./reventless/local",
      testMatch: [
        "<rootDir>/tests/**/*Test.res.mjs",
        "<rootDir>/tests/**/*_GWT.res.mjs",
      ],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "reventless-interop",
      rootDir: "./reventless/interop",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "reventless-spec",
      rootDir: "./reventless/spec",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "reventless-seed",
      rootDir: "./reventless/seed",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "reventless-seed-aws",
      rootDir: "./reventless/seed-aws",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "rescript-moment",
      rootDir: "./rescript/moment",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "online-shop-dcb-catalog",
      rootDir: "./examples/online-shop-dcb/catalog",
      testMatch: ["<rootDir>/tests/**/*_GWT.res.mjs"],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "online-shop-dcb-ordering",
      rootDir: "./examples/online-shop-dcb/ordering",
      testMatch: ["<rootDir>/tests/**/*_GWT.res.mjs"],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "example-aggregate-catalog",
      rootDir: "./examples/online-shop-aggregates/catalog",
      testMatch: ["<rootDir>/tests/**/*_GWT.res.mjs"],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "example-aggregate-ordering",
      rootDir: "./examples/online-shop-aggregates/ordering",
      testMatch: ["<rootDir>/tests/**/*_GWT.res.mjs"],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "online-shop-hybrid-catalog",
      rootDir: "./examples/online-shop-hybrid/catalog",
      testMatch: ["<rootDir>/tests/**/*_GWT.res.mjs"],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../../node_modules/spdx-exceptions/index.json",
      },
    },
    {
      displayName: "online-shop-hybrid-ordering",
      rootDir: "./examples/online-shop-hybrid/ordering",
      testMatch: ["<rootDir>/tests/**/*_GWT.res.mjs"],
      moduleFileExtensions: ["js", "mjs", "cjs"],
      setupFiles: [setupFile, sqliteGlobalSetup],
      moduleNameMapper: {
        "^node:sqlite$": sqliteBridge,
        "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
        "^spdx-license-ids$":
          "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
        "^spdx-license-ids/deprecated$":
          "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
        "^spdx-exceptions$":
          "<rootDir>/../../../node_modules/spdx-exceptions/index.json",
      },
    },
  ],
};

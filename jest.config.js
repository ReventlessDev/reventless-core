const path = require("path");

const setupFile = path.resolve(__dirname, "jest.setup.cjs");
// node:sqlite cannot be resolved by Jest 27's CJS resolver. The bridge .mjs
// pulls the real module off globalThis (populated by sqliteGlobal setup) so
// any project that transitively loads reventless-local still resolves it.
const sqliteBridge = path.resolve(
  __dirname,
  "reventless/reventless-local/__mocks__/nodeSqlite.mjs",
);
const sqliteGlobalSetup = path.resolve(
  __dirname,
  "reventless/reventless-local/tests/setup/sqliteGlobal.cjs",
);

/** @type {import('jest').Config} */
module.exports = {
  reporters: ["<rootDir>/jest.reporter.js"],
  watchPathIgnorePatterns: ["<rootDir>/.+/lib/bs/"],
  projects: [
    {
      displayName: "rescript-pulumi-aws",
      rootDir: "./rescript/rescript-pulumi-aws",
      testMatch: ["<rootDir>/tests/**/*Test.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
      moduleNameMapper: {
        "^@aws-appsync/utils$": "<rootDir>/tests/__mocks__/appsync-utils.mjs",
      },
    },
    {
      displayName: "reventless-core",
      rootDir: "./reventless/reventless-core",
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
      rootDir: "./reventless/reventless-gwt",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "reventless-local",
      rootDir: "./reventless/reventless-local",
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
      rootDir: "./reventless/reventless-interop",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      setupFiles: [setupFile],
    },
    {
      displayName: "rescript-moment",
      rootDir: "./rescript/rescript-moment",
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

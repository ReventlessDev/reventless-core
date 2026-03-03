/** @type {import('jest').Config} */
module.exports = {
  reporters: ["<rootDir>/jest.reporter.js"],
  watchPathIgnorePatterns: ["<rootDir>/.+/lib/bs/"],
  projects: [
    {
      displayName: "reventless-core",
      rootDir: "./reventless/reventless-core",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      testPathIgnorePatterns: [
        "/node_modules/",
        "<rootDir>/tests/AsyncTest.res.mjs",
        "<rootDir>/tests/BehaviorTest.res.mjs",
        "<rootDir>/tests/EventMappingTest.res.mjs",
        "<rootDir>/tests/ProjectionTest.res.mjs",
      ],
      moduleFileExtensions: ["js", "mjs"],
    },
    {
      displayName: "reventless-in-memory",
      rootDir: "./reventless/reventless-in-memory",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
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
      displayName: "reventless-interop",
      rootDir: "./reventless/reventless-interop",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
    },
    {
      displayName: "rescript-moment",
      rootDir: "./rescript/rescript-moment",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
    },
    {
      displayName: "example-dcb-catalog",
      rootDir: "./examples/dcb/catalog",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      moduleNameMapper: {
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
      displayName: "example-dcb-ordering",
      rootDir: "./examples/dcb/ordering",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      moduleNameMapper: {
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
      rootDir: "./examples/aggregate/catalog",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      moduleNameMapper: {
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
      rootDir: "./examples/aggregate/ordering",
      testMatch: ["<rootDir>/tests/**/*Test.res.mjs"],
      moduleFileExtensions: ["js", "mjs"],
      moduleNameMapper: {
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

// Child process for JestTest.mjs: runs the fixture suites through the
// `@jest/core` it is given. Jest 30 is installed as `@jest/core` alone, since
// a second package with a `jest` bin would take over the repo's `jest`.
//
// Usage: node runFixtures.mjs <@jest/core entry> <fixtures dir> <output file>

import { createRequire } from "node:module";

const [coreEntry, fixturesDir, outputFile] = process.argv.slice(2);
const { runCLI } = createRequire(import.meta.url)(coreEntry);

const config = { rootDir: fixturesDir, testMatch: ["<rootDir>/*Fixture.res.mjs"] };
await runCLI(
  {
    $0: "jest",
    _: [],
    config: JSON.stringify(config),
    ci: true,
    watchman: false,
    silent: true,
    json: true,
    outputFile,
  },
  [fixturesDir],
);

// Runs the fixture suites in a child Jest, once per supported major, and
// checks each test's outcome. Some fixtures exist to fail, so they cannot run
// in this Jest: a failing test there would fail the repo's run.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const testsDir = path.dirname(fileURLToPath(import.meta.url));
const fixturesDir = path.join(testsDir, "fixtures");

const expected = {
  "matchers toBe passes": "passed",
  "matchers not_ toBe passes": "passed",
  "matchers toEqual passes": "passed",
  "matchers toBeCloseTo passes": "passed",
  "matchers toBeSoCloseTo passes": "passed",
  "matchers toBeGreaterThan passes": "passed",
  "matchers toBeLessThanOrEqual passes": "passed",
  "matchers toBeSupersetOf passes": "passed",
  "matchers toContain passes": "passed",
  "matchers toContainEqual passes": "passed",
  "matchers toContainString passes": "passed",
  "matchers toHaveLength passes": "passed",
  "matchers toMatch passes": "passed",
  "matchers toMatchRe passes": "passed",
  "matchers toThrow passes": "passed",
  "matchers expectFn toThrow passes": "passed",
  "matchers Operators pass": "passed",
  "matchers pass passes": "passed",
  "runners testPromise passes": "passed",
  "runners the next test starts after testPromise settles passes": "passed",
  "runners testAsync passes": "passed",
  "runners testAll passes - 1": "passed",
  "runners testAll passes - 2": "passed",
  "runners testAllPromise passes - a": "passed",
  "hooks first test sees beforeAll and beforeEach passes": "passed",
  "hooks second test sees afterEach passes": "passed",
  "timers advanceTimersByTime passes": "passed",
  "timers setSystemTime passes": "passed",
  "checked now a failing assertion in the middle fails": "failed",
  "checked now a testPromise failing after a delay fails": "failed",
  "checked now a testAsync that never calls done times out": "failed",
  "checked now fail fails": "failed",
  "checked now Skip.test is skipped": "pending",
  "checked now Todo.test is a todo": "todo",
  "Only.test passes": "passed",
  "a test beside Only.test is skipped": "pending",
};

// The failure each failing test must report: its own, not a neighbour's.
const failureMessages = {
  "checked now a failing assertion in the middle fails": /Expected: 2[\s\S]*Received: 1/,
  "checked now a testPromise failing after a delay fails": /Expected: "on time"/,
  "checked now a testAsync that never calls done times out": /Exceeded timeout of 200 ms/,
  "checked now fail fails": /failed on purpose/,
};

const runFixtures = jestCore => {
  const outputFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "rescript-jest-")), "out.json");
  const child = spawnSync(
    process.execPath,
    [path.join(testsDir, "runFixtures.mjs"), jestCore, fixturesDir, outputFile],
    {
      encoding: "utf8",
      env: { ...process.env, NODE_OPTIONS: "--experimental-vm-modules --no-warnings" },
    },
  );
  if (!fs.existsSync(outputFile)) {
    throw new Error(`the child Jest wrote no results:\n${child.stderr}`);
  }
  const report = JSON.parse(fs.readFileSync(outputFile, "utf8"));
  return report.testResults.flatMap(suite => {
    if (suite.status === "failed" && suite.assertionResults.length === 0) {
      throw new Error(`a fixture suite failed to run:\n${suite.message}`);
    }
    return suite.assertionResults;
  });
};

describe.each([
  ["Jest 29", "@jest/core"],
  ["Jest 30", "jest-core-30"],
])("%s", (_major, jestCore) => {
  let results;
  beforeAll(() => {
    results = runFixtures(require.resolve(jestCore));
  }, 60_000);

  test("runs exactly the fixture tests", () => {
    expect(results.map(r => r.fullName).sort()).toEqual(Object.keys(expected).sort());
  });

  test.each(Object.entries(expected))("%s → %s", (name, status) => {
    const result = results.find(r => r.fullName === name);
    expect(result?.status).toBe(status);
    if (failureMessages[name]) {
      expect(result.failureMessages.join("\n")).toMatch(failureMessages[name]);
    }
  });
});

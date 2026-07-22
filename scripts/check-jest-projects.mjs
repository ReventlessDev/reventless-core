// Fail if a declared jest project discovers no test suites.
//
// Jest matches testMatch against files on disk. When a package's compiled
// `.res.mjs` test outputs are absent, the project resolves to zero suites and
// jest **exits 0** — a silent pass. That is how `reventless/core` (49 suites,
// 518 tests) and `reventless/aws` (21 suites, 280 tests) went unrun in CI
// without anything going red. See docs/plans/ci-unit-test-coverage-gap.md.
//
// Projects listed in KNOWN_EMPTY are the documented remainder of that gap. They
// are expected to be zero today; the check fails if one of them starts
// discovering suites (delete the entry) or if any OTHER project drops to zero.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Tracked in docs/plans/ci-unit-test-coverage-gap.md — their rescript.json marks
// `tests` as `type: "dev"`, so the root build never emits their test outputs.
// Remove an entry as each package is wired up; the check then enforces it.
const KNOWN_EMPTY = new Set(["reventless-core", "reventless-interop"]);

const { projects } = require(path.join(repoRoot, "jest.config.js"));

// Run the installed jest bin directly rather than shelling out to `npx`: jest is not
// declared as a dependency anywhere (the root scripts get it off PATH via pnpm's
// hoist), and `npx` would try to DOWNLOAD an unresolvable package rather than fail.
// `require.resolve("jest/bin/jest.js")` is not an option — jest's `exports` map
// blocks that subpath (ERR_PACKAGE_PATH_NOT_EXPORTED).
const jestBin = path.join(repoRoot, "node_modules", ".bin", "jest");
if (!fs.existsSync(jestBin)) {
  console.error(`jest binary not found at ${jestBin} — run \`pnpm install\` first.`);
  process.exit(1);
}

const listed = JSON.parse(
  execFileSync(process.execPath, [jestBin, "--listTests", "--json"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"],
    env: {
      ...process.env,
      NODE_OPTIONS: "--experimental-vm-modules --no-warnings",
    },
  }),
);

const failures = [];
const rows = projects.map((project) => {
  const root = path.resolve(repoRoot, project.rootDir);
  const count = listed.filter((f) => f.startsWith(root + path.sep)).length;
  const expectedEmpty = KNOWN_EMPTY.has(project.displayName);

  if (count === 0 && !expectedEmpty) {
    failures.push(
      `${project.displayName}: discovers 0 suites. Its test outputs are missing, ` +
        `so jest would silently pass. Build the package, or add it to KNOWN_EMPTY ` +
        `with a note in docs/plans/ci-unit-test-coverage-gap.md.`,
    );
  }
  if (count > 0 && expectedEmpty) {
    failures.push(
      `${project.displayName}: now discovers ${count} suites but is still listed in ` +
        `KNOWN_EMPTY. Remove it so the check enforces the project from now on.`,
    );
  }
  return { name: project.displayName, count, expectedEmpty };
});

const width = Math.max(...rows.map((r) => r.name.length));
for (const { name, count, expectedEmpty } of rows) {
  const mark = count === 0 ? (expectedEmpty ? "skip" : "FAIL") : "ok";
  console.log(`  ${mark.padEnd(5)} ${name.padEnd(width)}  ${count}`);
}
console.log(`  ${listed.length} suites across ${projects.length} projects`);

if (failures.length > 0) {
  console.error("\njest project check failed:\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

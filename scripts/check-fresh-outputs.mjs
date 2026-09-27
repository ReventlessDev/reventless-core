#!/usr/bin/env node
// Fails when a build changed the compiled outputs the repository tracks.
//
// Tracked `.res.mjs` / `.res.js` files are what Pulumi, `pnpm run run` and the
// published example packages load, so they have to be what the current sources
// and the current PPX compile to. A PPX change that alters its output does not
// touch them on its own: they stay as the last person to rebuild left them, and
// nothing notices until someone else's build rewrites them in an unrelated diff.
//
// Run it straight after a build from a clean checkout. It reports a tracked
// output the build modified or deleted, and one it wrote that is neither
// tracked nor ignored (a new source whose output was never committed).
//
// Usage: node scripts/check-fresh-outputs.mjs   (exit 1 on stale outputs)

import { execFileSync } from "node:child_process"

const isOutput = (path) => path.endsWith(".res.mjs") || path.endsWith(".res.js")

const status = execFileSync("git", ["status", "--porcelain", "-z", "--untracked-files=all"], {
  encoding: "utf8",
})

// `-z` entries are `XY path`, and a rename carries its source as the next entry.
const entries = status.split("\0").filter(Boolean)
const stale = []
for (let i = 0; i < entries.length; i++) {
  const code = entries[i].slice(0, 2)
  const path = entries[i].slice(3)
  if (code.startsWith("R") || code.startsWith("C")) i++
  if (isOutput(path)) stale.push({ code, path })
}

if (stale.length === 0) {
  console.log("ok  every tracked compiled output matches a fresh build")
  process.exit(0)
}

const label = (code) =>
  code === "??" ? "not committed" : code.includes("D") ? "deleted by the build" : "stale"

console.error(
  `\n✖ ${stale.length} compiled output(s) differ from what the build just wrote.\n` +
    `  Rebuild and commit them with the change that moved them:\n` +
    `    git ls-files '*.res' | xargs touch && pnpm run build\n` +
    `  Locally, rebuild the PPX first if its source changed since your last\n` +
    `  build: an older binary compiles differently.\n` +
    `    pnpm --filter @reventlessdev/reventless-ppx run build:ppx\n` +
    `  and copy its src/_build/default/bin/bin.exe over the ppx-<platform>.exe\n` +
    `  the package's bin shim runs.\n`,
)
for (const { code, path } of stale.slice(0, 30)) console.error(`    ${label(code)}  ${path}`)
if (stale.length > 30) console.error(`    …and ${stale.length - 30} more`)
console.error("")
process.exit(1)

#!/usr/bin/env node
// Guard against committing the "ReScript full-clean wiped tracked .res.mjs"
// footgun. When `rescript build` detects a compiler-version change it does a
// full clean that deletes the in-source compiled outputs; if the follow-up
// build then fails before re-emitting, those tracked outputs stay deleted and
// can slip into a commit (and break CI / `jest`, which resolves the .res.mjs).
//
// This script fails when a tracked compiled output (`.res.mjs` / `.res.js`) is
// deleted from the working tree WHILE its ReScript source (`.res`) is still
// present — i.e. an orphaned output, the signature of the wipe. Deleting both
// the source and its output together is a legitimate removal and is ignored.
//
// Usage: node scripts/check-tracked-outputs.mjs   (exit 1 on violation)
// Wired as a pre-commit hook by scripts/install-git-hooks.mjs.

import { execSync } from "node:child_process"
import { existsSync } from "node:fs"

const run = (cmd) => execSync(cmd, { encoding: "utf8" }).trim()

let root
try {
  root = run("git rev-parse --show-toplevel")
} catch {
  process.exit(0) // not a git repo — nothing to guard
}

const deleted = run("git ls-files --deleted")
  .split("\n")
  .filter(Boolean)
  .filter((f) => f.endsWith(".res.mjs") || f.endsWith(".res.js"))

// An output is "orphaned" when its .res source still exists on disk.
const orphaned = deleted.filter((out) => {
  const src = out.replace(/\.res\.(mjs|js)$/, ".res")
  return existsSync(`${root}/${src}`)
})

if (orphaned.length === 0) process.exit(0)

console.error(
  `\n✖ ${orphaned.length} tracked ReScript output(s) are deleted while their .res source still exists.\n` +
    `  This is the "compiler-update full clean wiped tracked .res.mjs" footgun.\n` +
    `  Regenerate them before committing:  pnpm run build\n` +
    `  (or restore:  git ls-files --deleted -z | xargs -0 git checkout --)\n`,
)
for (const f of orphaned.slice(0, 20)) console.error(`    - ${f}`)
if (orphaned.length > 20) console.error(`    …and ${orphaned.length - 20} more`)
console.error("")
process.exit(1)

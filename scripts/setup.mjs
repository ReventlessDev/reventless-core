#!/usr/bin/env node
// One-command onboarding bootstrap for a fresh clone. Idempotent — safe to
// re-run. Performs, in order:
//
//   1. Create pnpm-workspace.yaml (gitignored symlink → pnpm-workspace.base.yaml)
//   2. Point git blame at .git-blame-ignore-revs so whole-tree reprints don't
//      mask authorship
//   3. pnpm install
//   4. Ensure a ReScript PPX binary exists for this platform (prebuilt from the
//      registry if available, otherwise built from source via opam/dune)
//   5. Seed the hybrid example's .reventless/users.yaml from its committed
//      users.example.yaml so local login works out of the box
//   6. Build the hybrid in-memory example (unless --no-build)
//
// Usage:
//   node scripts/setup.mjs            # full bootstrap
//   node scripts/setup.mjs --no-build # skip the final example build
//
// Run from the repo root.

import { execSync } from 'node:child_process'
import { existsSync, copyFileSync, chmodSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const NO_BUILD = process.argv.includes('--no-build')

const run = (cmd, opts = {}) =>
  execSync(cmd, { cwd: ROOT, stdio: 'inherit', ...opts })
const step = (n, msg) => console.log(`\n[setup ${n}/6] ${msg}`)
const ok = (msg) => console.log(`  ✓ ${msg}`)
const warn = (msg) => console.warn(`  ⚠ ${msg}`)

// ── 1. Workspace symlink ────────────────────────────────────────────────────
step(1, 'Workspace config (pnpm-workspace.yaml)')
run('node scripts/workspace-setup.mjs')

// ── 2. Blame ignore file ────────────────────────────────────────────────────
step(2, 'git blame ignore file')
configureBlameIgnore()

// ── 3. Install ──────────────────────────────────────────────────────────────
step(3, 'Installing dependencies (pnpm install)')
run('pnpm install')

// ── 4. PPX binary ───────────────────────────────────────────────────────────
step(4, 'ReScript PPX binary')
ensurePpx()

// ── 5. Seed example users ───────────────────────────────────────────────────
step(5, 'Local dev users for the hybrid example')
seedUsers()

// ── 6. Build the example ────────────────────────────────────────────────────
if (NO_BUILD) {
  step(6, 'Skipping example build (--no-build)')
} else {
  step(6, 'Building the hybrid in-memory example')
  run('pnpm --filter ./examples/online-shop-hybrid/platform-local run build')
}

console.log(`
✅ Setup complete.

Run the example backend (GraphQL + MCP):
  cd examples/online-shop-hybrid/platform-local && pnpm run serve

Then log in (Domain GraphQL server) as admin/admin:
  curl -s -X POST http://localhost:4000/__inmemory/login \\
    -H 'content-type: application/json' \\
    -d '{"username":"admin","password":"admin"}'
`)

// ── helpers ──────────────────────────────────────────────────────────────────

function ensurePpx() {
  const PLATFORM = `${process.platform}-${process.arch}`
  // (platform → published per-platform package suffix, local-build fallback name)
  // Mirrors packages/reventless-ppx/bin.
  const MAP = {
    'linux-x64': ['linux-x64', 'ppx-linux.exe'],
    'linux-arm64': ['linux-arm64', 'ppx-linux-arm.exe'],
    'darwin-x64': ['darwin-x64', 'ppx-osx-x64.exe'],
    'darwin-arm64': ['darwin-arm64', 'ppx-osx.exe'],
  }
  const entry = MAP[PLATFORM]
  if (!entry) {
    warn(`Unsupported platform ${PLATFORM}. On Windows, run inside WSL2 (Linux-x64).`)
    return
  }
  const [pkg, local] = entry
  const ppxDir = join(ROOT, 'packages/reventless-ppx')
  const candidates = [
    join(ROOT, `node_modules/@reventlessdev/reventless-ppx-${pkg}/ppx.exe`),
    join(ppxDir, `node_modules/@reventlessdev/reventless-ppx-${pkg}/ppx.exe`),
    join(ppxDir, local),
    join(ppxDir, `npm/${pkg}/ppx.exe`),
  ]
  if (candidates.some(existsSync)) {
    ok(`prebuilt binary found for ${PLATFORM}`)
    return
  }
  // No prebuilt binary for this platform — build from source if the OCaml
  // toolchain is available.
  if (!hasOpam()) {
    warn(
      `No prebuilt PPX for ${PLATFORM} and opam/dune not found.\n` +
        `    Install the OCaml toolchain (https://opam.ocaml.org/doc/Install.html),\n` +
        `    then re-run, or build manually:\n` +
        `      (cd packages/reventless-ppx/src && opam exec -- dune build)\n` +
        `      cp packages/reventless-ppx/src/_build/default/bin/bin.exe packages/reventless-ppx/${local}`,
    )
    return
  }
  console.log('  building PPX from source (opam exec -- dune build)…')
  run('opam exec -- dune build', { cwd: join(ppxDir, 'src') })
  copyFileSync(join(ppxDir, 'src/_build/default/bin/bin.exe'), join(ppxDir, local))
  chmodSync(join(ppxDir, local), 0o755)
  ok(`built ${local} from source for ${PLATFORM}`)
}

// Git reads .git-blame-ignore-revs only when pointed at it. Without this a
// whole-tree reprint credits every re-indented line to the reprint.
function configureBlameIgnore() {
  if (!existsSync(join(ROOT, '.git-blame-ignore-revs'))) {
    warn('.git-blame-ignore-revs not found — skipping')
    return
  }
  try {
    execSync('git config blame.ignoreRevsFile .git-blame-ignore-revs', {
      cwd: ROOT,
      stdio: 'ignore',
    })
    ok('blame.ignoreRevsFile set')
  } catch {
    warn('could not set blame.ignoreRevsFile (not a git checkout?)')
  }
}

function hasOpam() {
  try {
    execSync('opam --version', { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

// Delegates to `prepare-accounts` (from reventless-spec) rather than doing its
// own copy: that command is the one implementation of "a manifest starts from
// its committed template", and the deployed platform reaches the same code
// through `provision-accounts`. Two copies of this had already drifted — the
// line printed here named a `user` account the template has never declared.
//
// It copies users.example.yaml into place and generates a password into any
// field left empty. The local template ships memorable ones, so here it only
// copies; the AWS template ships empty ones, so there it mints four. Same
// command, and the declaration is what differs.
//
// Safe this early in the bootstrap: the compiled CLI is a tracked output, so it
// is on disk before step 6 builds anything, its only dependency (yaml) arrived
// with step 3, and step 3 is also what links the bin.
function seedUsers() {
  const platform = join(ROOT, 'examples/online-shop-hybrid/platform-local')
  if (existsSync(join(platform, '.reventless/users.yaml'))) {
    ok('.reventless/users.yaml already present')
    return
  }
  if (!existsSync(join(platform, 'users.example.yaml'))) {
    warn('users.example.yaml not found — skipping user seed')
    return
  }
  run('pnpm exec prepare-accounts', { cwd: platform })
}

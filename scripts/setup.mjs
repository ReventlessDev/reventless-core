#!/usr/bin/env node
// One-command onboarding bootstrap for a fresh clone. Idempotent — safe to
// re-run. Performs, in order:
//
//   1. Create pnpm-workspace.yaml (gitignored symlink → pnpm-workspace.base.yaml)
//   2. pnpm install
//   3. Ensure a ReScript PPX binary exists for this platform (prebuilt from the
//      registry if available, otherwise built from source via opam/dune)
//   4. Seed the hybrid example's .reventless/users.yaml from its committed
//      users.example.yaml so local login works out of the box
//   5. Build the hybrid in-memory example (unless --no-build)
//
// Usage:
//   node scripts/setup.mjs            # full bootstrap
//   node scripts/setup.mjs --no-build # skip the final example build
//
// Run from the repo root.

import { execSync } from 'node:child_process'
import {
  existsSync,
  copyFileSync,
  mkdirSync,
  chmodSync,
} from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const NO_BUILD = process.argv.includes('--no-build')

const run = (cmd, opts = {}) =>
  execSync(cmd, { cwd: ROOT, stdio: 'inherit', ...opts })
const step = (n, msg) => console.log(`\n[setup ${n}/5] ${msg}`)
const ok = (msg) => console.log(`  ✓ ${msg}`)
const warn = (msg) => console.warn(`  ⚠ ${msg}`)

// ── 1. Workspace symlink ────────────────────────────────────────────────────
step(1, 'Workspace config (pnpm-workspace.yaml)')
run('node scripts/workspace-setup.mjs')

// ── 2. Install ──────────────────────────────────────────────────────────────
step(2, 'Installing dependencies (pnpm install)')
run('pnpm install')

// ── 3. PPX binary ───────────────────────────────────────────────────────────
step(3, 'ReScript PPX binary')
ensurePpx()

// ── 4. Seed example users ───────────────────────────────────────────────────
step(4, 'Local dev users for the hybrid example')
seedUsers()

// ── 5. Build the example ────────────────────────────────────────────────────
if (NO_BUILD) {
  step(5, 'Skipping example build (--no-build)')
} else {
  step(5, 'Building the hybrid in-memory example')
  run('pnpm --filter ./examples/online-shop-hybrid/platform-in-memory run build')
}

console.log(`
✅ Setup complete.

Run the example backend (GraphQL + MCP):
  cd examples/online-shop-hybrid/platform-in-memory && pnpm run serve

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

function hasOpam() {
  try {
    execSync('opam --version', { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

function seedUsers() {
  const dir = join(
    ROOT,
    'examples/online-shop-hybrid/platform-in-memory/.reventless',
  )
  const target = join(dir, 'users.yaml')
  const example = join(
    ROOT,
    'examples/online-shop-hybrid/platform-in-memory/users.example.yaml',
  )
  if (existsSync(target)) {
    ok('.reventless/users.yaml already present')
    return
  }
  if (!existsSync(example)) {
    warn('users.example.yaml not found — skipping user seed')
    return
  }
  mkdirSync(dir, { recursive: true })
  copyFileSync(example, target)
  ok('seeded .reventless/users.yaml (admin/admin, user/user)')
}

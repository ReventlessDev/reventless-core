#!/usr/bin/env node
// Build and publish ONE per-platform reventless-ppx binary package to the
// registry from a developer machine.
//
// Most targets are built + published by CI (.github/workflows/publish-ppx.yml).
// `darwin-x64` (Intel macOS) is intentionally NOT in that matrix — Intel is a
// sunsetting target and we don't want to spend macOS CI minutes on it. Instead,
// whenever the PPX source changes, an Intel-Mac maintainer republishes it with
// this script, keeping the version in lockstep with the CI-built packages.
//
// Requirements:
//   - Run ON the target platform (the binary is native; no cross-compile).
//   - OCaml toolchain (opam + dune) installed.
//   - GITHUB_TOKEN in the environment (the @reventlessdev scope routes to
//     GitHub Packages via .npmrc).
//
// Usage (from repo root, or via `pnpm --filter @reventlessdev/reventless-ppx run publish:platform`):
//   node scripts/publish-ppx-local.mjs            # target = current platform
//   node scripts/publish-ppx-local.mjs darwin-x64 # explicit target
//   node scripts/publish-ppx-local.mjs --dry-run  # build + stage, skip publish

import { execSync } from 'node:child_process'
import { existsSync, copyFileSync, chmodSync, readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const PPX = join(ROOT, 'packages/reventless-ppx')

const argv = process.argv.slice(2)
const DRY_RUN = argv.includes('--dry-run')
const requested = argv.find((a) => !a.startsWith('-'))

const HOST = `${process.platform}-${process.arch}` // e.g. darwin-x64
const target = requested ?? HOST

const VALID = ['darwin-x64', 'darwin-arm64', 'linux-x64', 'linux-arm64']
if (!VALID.includes(target)) {
  fail(`Unknown target "${target}". Expected one of: ${VALID.join(', ')}`)
}
if (target !== HOST) {
  fail(
    `Cannot build ${target} on ${HOST} — the binary is native, no cross-compile.\n` +
      `  Run this script on a ${target} machine.`,
  )
}
if (!DRY_RUN && !process.env.GITHUB_TOKEN) {
  fail('GITHUB_TOKEN is not set (required to publish to GitHub Packages).')
}

const pkgDir = join(PPX, 'npm', target)
if (!existsSync(pkgDir)) fail(`Missing per-platform package dir: ${pkgDir}`)

// main's version is the single source of truth — generate the scaffold's version
// from it before publish so the two can never disagree (lerna bumps only main;
// npm/* is not a workspace member). This is the local-publish twin of the CI
// "Sync per-platform version from main" step in publish-ppx.yml.
const mainVersion = JSON.parse(readFileSync(join(PPX, 'package.json'), 'utf8')).version
const scaffoldPath = join(pkgDir, 'package.json')
const scaffold = JSON.parse(readFileSync(scaffoldPath, 'utf8'))
if (scaffold.version !== mainVersion) {
  scaffold.version = mainVersion
  writeFileSync(scaffoldPath, JSON.stringify(scaffold, null, 2) + '\n')
  console.log(`▶ Set npm/${target} version → ${mainVersion} (from main)`)
}
const thisVersion = mainVersion

console.log(`▶ Building PPX from source for ${target}…`)
execSync('opam exec -- dune build', { cwd: join(PPX, 'src'), stdio: 'inherit' })

const binSrc = join(PPX, 'src/_build/default/bin/bin.exe')
const binDst = join(pkgDir, 'ppx.exe')
copyFileSync(binSrc, binDst)
chmodSync(binDst, 0o755)
console.log(`▶ Staged binary → npm/${target}/ppx.exe`)

if (DRY_RUN) {
  console.log(`✓ Dry run — built and staged ${target}@${thisVersion}, skipped publish.`)
  process.exit(0)
}

console.log(`▶ Publishing @reventlessdev/reventless-ppx-${target}@${thisVersion} to GitHub Packages…`)
try {
  execSync('npm publish', { cwd: pkgDir, stdio: 'inherit' })
  console.log(`✅ Published ${target}@${thisVersion}.`)
} catch {
  console.warn(
    `⚠ Publish failed — most likely ${thisVersion} already exists in the registry ` +
      `(publishing an existing version is a no-op). Bump main's version ` +
      `(packages/reventless-ppx/package.json) if you intend a new release — the ` +
      `scaffold version is generated from it.`,
  )
  process.exit(1)
}

function fail(msg) {
  console.error(`[publish-ppx-local] ${msg}`)
  process.exit(1)
}

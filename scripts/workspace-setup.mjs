#!/usr/bin/env node
// One-time bootstrap: create pnpm-workspace.yaml as a symlink to
// pnpm-workspace.base.yaml so pnpm install has a workspace config to read.
//
// Fresh clones need this because pnpm-workspace.yaml is gitignored (see
// docs/guides/cross-repo-dev-linking.md). Idempotent — does nothing if
// pnpm-workspace.yaml already exists.

import { existsSync, lstatSync, symlinkSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

// Anchor to the repo root (parent of scripts/) so this works regardless of the
// caller's cwd — e.g. the deploy-docs workflow invokes it from packages/doc.
const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const BASE = 'pnpm-workspace.base.yaml'
const TARGET = 'pnpm-workspace.yaml'
const BASE_PATH = join(ROOT, BASE)
const TARGET_PATH = join(ROOT, TARGET)

if (!existsSync(BASE_PATH)) {
  console.error(`[setup] ${BASE_PATH} not found. Is the repo checked out correctly?`)
  process.exit(1)
}

if (existsSync(TARGET_PATH)) {
  const stats = lstatSync(TARGET_PATH)
  if (stats.isSymbolicLink()) {
    console.log(`[setup] ${TARGET} already a symlink — nothing to do.`)
  } else {
    console.log(`[setup] ${TARGET} already exists (not a symlink — link mode?). Leaving untouched.`)
  }
  process.exit(0)
}

// Keep the symlink target relative so the link stays portable.
symlinkSync(BASE, TARGET_PATH)
console.log(`[setup] Created ${TARGET} → ${BASE} (release mode).`)

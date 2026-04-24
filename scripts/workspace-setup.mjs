#!/usr/bin/env node
// One-time bootstrap: create pnpm-workspace.yaml as a symlink to
// pnpm-workspace.base.yaml so pnpm install has a workspace config to read.
//
// Fresh clones need this because pnpm-workspace.yaml is gitignored (see
// docs/guides/cross-repo-dev-linking.md). Idempotent — does nothing if
// pnpm-workspace.yaml already exists.

import { existsSync, lstatSync, symlinkSync } from 'node:fs'

const BASE = 'pnpm-workspace.base.yaml'
const TARGET = 'pnpm-workspace.yaml'

if (!existsSync(BASE)) {
  console.error(`[setup] ${BASE} not found. Are you in the repo root?`)
  process.exit(1)
}

if (existsSync(TARGET)) {
  const stats = lstatSync(TARGET)
  if (stats.isSymbolicLink()) {
    console.log(`[setup] ${TARGET} already a symlink — nothing to do.`)
  } else {
    console.log(`[setup] ${TARGET} already exists (not a symlink — link mode?). Leaving untouched.`)
  }
  process.exit(0)
}

symlinkSync(BASE, TARGET)
console.log(`[setup] Created ${TARGET} → ${BASE} (release mode).`)

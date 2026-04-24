#!/usr/bin/env node
// Restores release mode: replaces pnpm-workspace.yaml (gitignored) with
// a symlink to pnpm-workspace.base.yaml, and reverts any pnpm.overrides
// entries a previous `pnpm link:on` merged into package.json. Invoked by
// `pnpm link:off`.

import { execSync } from 'node:child_process'
import { existsSync, lstatSync, symlinkSync, unlinkSync } from 'node:fs'

const BASE = 'pnpm-workspace.base.yaml'
const TARGET = 'pnpm-workspace.yaml'

if (!existsSync(BASE)) {
  console.error(`[restore] ${BASE} not found. Are you in the repo root?`)
  process.exit(1)
}

if (lstatSync(TARGET, { throwIfNoEntry: false })) {
  try {
    unlinkSync(TARGET)
  } catch (err) {
    if (err.code !== 'ENOENT') throw err
  }
}

symlinkSync(BASE, TARGET)
console.log(`[restore] ${TARGET} → ${BASE} (release mode).`)

// Undo any overrides the overlay merged into package.json.
execSync(`git checkout -- package.json`, { stdio: 'inherit' })
console.log(`[restore] package.json restored from git index.`)

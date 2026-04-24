#!/usr/bin/env node
// Reports whether `pnpm link:on` is currently active.
//
// pnpm-workspace.yaml is gitignored and is either:
//   - a symlink to pnpm-workspace.base.yaml (release mode), or
//   - a regular file containing the merged overlay (link mode).
// Invoked by `pnpm link:status`.

import { existsSync, lstatSync } from 'node:fs'

const TARGET = 'pnpm-workspace.yaml'

if (!existsSync(TARGET)) {
  console.error(`[status] ${TARGET} not found.`)
  console.error(`[status] Run \`node scripts/workspace-setup.mjs\` to create the symlink.`)
  process.exit(1)
}

const stats = lstatSync(TARGET)
if (stats.isSymbolicLink()) {
  console.log('release mode — pnpm link:off')
} else {
  console.log('link mode — pnpm link:on')
}

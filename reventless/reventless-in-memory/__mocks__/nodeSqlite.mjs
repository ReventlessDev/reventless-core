// Bridge to node:sqlite for Jest 27, which cannot resolve `node:` URI imports.
// The companion `tests/setup/sqliteGlobal.cjs` (registered as a Jest setupFile)
// pre-loads the real module onto globalThis from the CJS environment.
const sqlite = globalThis.__nodeSqlite
export const DatabaseSync = sqlite.DatabaseSync
export const StatementSync = sqlite.StatementSync

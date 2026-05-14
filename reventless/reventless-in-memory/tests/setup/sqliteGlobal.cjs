// Pre-loads node:sqlite onto globalThis so the bridge .mjs can pull it
// without going through Jest's resolver (which on Jest 27 fails for `node:` URIs).
// process.getBuiltinModule (Node 22.16+) bypasses the module loader entirely.
globalThis.__nodeSqlite = process.getBuiltinModule("node:sqlite");

// Jest 27's ESM VM context does not expose globalThis.crypto. uuid@13's
// `default` export (dist/rng.js) depends on it, so Uuid.v4() throws
// "crypto.getRandomValues() not supported". Polyfill from node:crypto.
if (!globalThis.crypto) {
  globalThis.crypto = require("node:crypto").webcrypto;
}


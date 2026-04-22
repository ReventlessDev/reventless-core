// Pre-loads node:sqlite onto globalThis so the bridge .mjs can pull it
// without going through Jest's resolver (which on Jest 27 fails for `node:` URIs).
// process.getBuiltinModule (Node 22.16+) bypasses the module loader entirely.
globalThis.__nodeSqlite = process.getBuiltinModule("node:sqlite");

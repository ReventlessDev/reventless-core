// Empties a scope of the local dev platform's store so it can be re-seeded — the
// local counterpart of `platform-aws`'s `seed:reset`, and the inverse of
// `pnpm run seed`.
//
//   pnpm run seed:reset      # pick a scope, see what it would empty, confirm
//
// It works against a RUNNING platform: rows are deleted through a second
// connection to the same database, which the server sees immediately. So the
// usual loop is `seed:reset` then `seed`, with the platform left up.
//
// The store is the one `REVENTLESS_LOCAL_BACKEND` selects, so this and the
// platform cannot disagree about which store is being reset. Scope defaults to
// `domain` (leaves the plugin registry intact, so a re-seed just works);
// `SEED_RESET_SCOPE` picks one non-interactively.

ReventlessLocal.LocalSeedReset.run()

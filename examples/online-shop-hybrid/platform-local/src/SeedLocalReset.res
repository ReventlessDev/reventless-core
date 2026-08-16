// Empties a scope of the local dev platform's store so it can be re-seeded — the
// local counterpart of `platform-aws`'s `seed:reset`, and the inverse of
// `pnpm run seed`.
//
//   pnpm run seed:reset      # pick a scope, see what it would empty, confirm
//
// It runs against a RUNNING platform — rows are deleted through a second
// connection to the same database — but **restart the platform before
// re-seeding**. The rows go, and the server's in-memory state does not: a DCB
// slice holds decision state per partition, so it goes on refusing writes for
// ids whose state it still remembers, and a re-seed fails with
// `…AlreadyExists` against a store that demonstrably does not contain them.
//
// The loop is `seed:reset` → restart → `seed`. This comment used to say the
// platform could be left up; it could not, and the symptom looked like the
// reset having silently done nothing.
//
// The store is the one `REVENTLESS_LOCAL_BACKEND` selects, so this and the
// platform cannot disagree about which store is being reset. Scope defaults to
// `domain` (leaves the plugin registry intact, so a re-seed just works);
// `SEED_RESET_SCOPE` picks one non-interactively.

ReventlessLocal.LocalSeedReset.run()

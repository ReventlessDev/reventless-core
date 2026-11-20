// A named, seedable data set. `seed` owns everything domain-specific — the
// phases, the view checks, the summary — so the runner never sees domain detail.
// `label` is what the selection menu shows.

type t = {
  name: string,
  label: string,
  seed: Seed_Connect.connection => promise<unit>,
  // View names probed by the fresh-store guard before any command is sent; a
  // non-empty one aborts the run at startup. Omit to skip the guard.
  probeViews?: array<string>,
  // Any other check that must pass before a command is sent — a set that adds to
  // an existing store refuses an empty one here. Throw `Failed` to refuse; the
  // run then reports that nothing was written.
  preflight?: Seed_Connect.connection => promise<unit>,
  // Whether `seed` may run again on the store its last run left: each run must
  // name new ids, and must leave the store whole when it ends.
  repeatable?: bool,
  // The pace this set plays at unless `SEED_PACE` says otherwise (see `Seed_Pace.parse`).
  pace?: string,
}

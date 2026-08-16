// Per-aggregate persisted-snapshot configuration
// (docs/plans/done/aggregate-snapshotting.md).
//
// Snapshotting is opt-in and lives on the Behavior module (where `state` is
// defined): `Behavior.T.snapshot = None` (the default, auto-injected by
// `@@reventless.behavior`) keeps full replay; `Some(config)` makes the
// aggregate write a keep-one snapshot every `interval` events and seed cold
// replays from the latest one. Snapshots are a read optimization only — the
// OCC append remains the sole consistency primitive, and a missing, corrupt,
// or schema-drifted snapshot degrades to full replay.
//
// Enable via the file-level attribute on a behavior file:
//
//   @@reventless.snapshots(100)
//
// which injects `let snapshot = Some({interval: 100, stateSchema})` (requires
// `@schema type state` so sury generates the schema), or hand-write the
// binding for full control.

type config<'state> = {
  /** Write a snapshot after every N appended events. Required — no default. */
  interval: int,
  /** Sury schema for the behavior's state — serializes the persisted snapshot
      and (hashed) gates staleness across state-shape changes. */
  stateSchema: S.t<'state>,
}

// ReScript bindings for Effect STM (Software Transactional Memory)
//
// STM<A, E, R> describes a transactional computation over TRef values.
// Transactions are executed atomically via optimistic concurrency — if any
// TRef read during the transaction changes before the transaction commits,
// it retries automatically. No deadlocks, no explicit locking.
//
// Use STM to fix the EventLog append/publish atomicity gap: wrap both
// the event storage write and the bus notification in a single STM commit.

// ─── STM type ────────────────────────────────────────────────────────────

type t<'a, 'e, 'r>

// Local alias so nested TRef module can reference the outer Stm.t without
// self-referencing "Stm" (which ReScript can't resolve inside the same file).
type stm<'a, 'e, 'r> = t<'a, 'e, 'r>

// ─── TRef type ───────────────────────────────────────────────────────────

// TRef<A> is a transactional mutable variable. Reads/writes inside STM
// are tracked so the runtime can detect conflicts and retry the transaction.
module TRef = {
  type t<'a>

  @module("effect") @scope("TRef")
  external make: 'a => stm<t<'a>, 'e, 'r> = "make"

  @module("effect") @scope("TRef")
  external get: t<'a> => stm<'a, 'e, 'r> = "get"

  @module("effect") @scope("TRef")
  external set: (t<'a>, 'a) => stm<unit, 'e, 'r> = "set"

  @module("effect") @scope("TRef")
  external update: (t<'a>, 'a => 'a) => stm<unit, 'e, 'r> = "update"

  @module("effect") @scope("TRef")
  external getAndUpdate: (t<'a>, 'a => 'a) => stm<'a, 'e, 'r> = "getAndUpdate"

  @module("effect") @scope("TRef")
  external modify: (t<'a>, 'a => ('b, 'a)) => stm<'b, 'e, 'r> = "modify"
}

// ─── STM construction ────────────────────────────────────────────────────

@module("effect") @scope("STM")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

@module("effect") @scope("STM")
external fail: 'e => t<'a, 'e, 'r> = "fail"

// Retry the transaction (will re-run when any read TRef changes)
@module("effect") @scope("STM")
external retry: t<'a, 'e, 'r> = "retry"

// ─── STM transformation ──────────────────────────────────────────────────

@module("effect") @scope("STM")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("STM")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

@module("effect") @scope("STM")
external zipRight: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "zipRight"

// ─── Running STM ─────────────────────────────────────────────────────────

// Execute the transaction atomically, retrying on conflict.
// Returns an Effect — transactions cannot be nested inside other Effects directly.
@module("effect") @scope("STM")
external commit: t<'a, 'e, 'r> => Effect.t<'a, 'e, 'r> = "commit"

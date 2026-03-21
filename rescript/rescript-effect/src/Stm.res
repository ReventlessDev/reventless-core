/**
ReScript bindings for `STM<A, E, R>` — Software Transactional Memory.

STM describes a transactional computation over `TRef` values. Transactions
commit atomically via *optimistic concurrency*: if any `TRef` read during
the transaction changes before it commits, the transaction retries automatically.

**Benefits over locks:**
- No deadlocks — transactions compose freely
- No explicit locking — the runtime handles conflict detection
- Automatic retry — the transaction waits and retries when data changes

**Example**
```rescript
let counter = Stm.TRef.make(0)->Stm.commit->Effect.runSync

// Atomic increment
counter
->Stm.TRef.update(n => n + 1)
->Stm.commit
->Effect.runPromise
```
*/

// ─── STM type ────────────────────────────────────────────────────────────

/** The core STM type — describes a transactional computation, not yet committed. */
type t<'a, 'e, 'r>

// Local alias so the nested TRef module can reference Stm.t without self-referencing "Stm".
type stm<'a, 'e, 'r> = t<'a, 'e, 'r>

// ─── TRef type ───────────────────────────────────────────────────────────

/**
`TRef<A>` is a transactional mutable variable.

Reads and writes inside an STM transaction are tracked so the runtime
can detect conflicts and retry when another transaction commits first.
*/
module TRef = {
  type t<'a>

  /** Creates a new `TRef` with `initial` value as an STM computation. */
  @module("effect/TRef")
  external make: 'a => stm<t<'a>, 'e, 'r> = "make"

  /** Reads the current value of the `TRef` in the current transaction. */
  @module("effect/TRef")
  external get: t<'a> => stm<'a, 'e, 'r> = "get"

  /** Sets the `TRef` to `value` in the current transaction. */
  @module("effect/TRef")
  external set: (t<'a>, 'a) => stm<unit, 'e, 'r> = "set"

  /** Applies a pure function to update the `TRef` value in the current transaction. */
  @module("effect/TRef")
  external update: (t<'a>, 'a => 'a) => stm<unit, 'e, 'r> = "update"

  /** Atomically applies `f`, storing the new value and returning the old one. */
  @module("effect/TRef")
  external getAndUpdate: (t<'a>, 'a => 'a) => stm<'a, 'e, 'r> = "getAndUpdate"

  /** Atomically applies `f` to produce both a result `'b` and a new value in one step. */
  @module("effect/TRef")
  external modify: (t<'a>, 'a => ('b, 'a)) => stm<'b, 'e, 'r> = "modify"
}

// ─── STM construction ────────────────────────────────────────────────────

/** Creates an STM computation that always succeeds with `value`. */
@module("effect/STM")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"

/** Creates an STM computation that always fails with the given typed error. */
@module("effect/STM")
external fail: 'e => t<'a, 'e, 'r> = "fail"

/**
Retries the current transaction.

The transaction will re-run when any `TRef` it has read changes value.
Use to implement blocking transactional reads (e.g. wait until a queue has items).
*/
@module("effect/STM")
external retry: t<'a, 'e, 'r> = "retry"

// ─── STM transformation ──────────────────────────────────────────────────

/** Transforms the success value with a pure function. */
@module("effect/STM")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

/** Chains STM computations — applies `f` to the success value, producing the next STM step. */
@module("effect/STM")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

/** Sequences two STM computations, discarding the first result. */
@module("effect/STM")
external zipRight: (t<'a, 'e, 'r>, t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "zipRight"

// ─── Running STM ─────────────────────────────────────────────────────────

/**
Commits the STM transaction atomically, returning an `Effect`.

If any `TRef` read during the transaction was modified by another transaction
before commit, the transaction retries automatically. Once committed, all
`TRef` writes become visible atomically to other fibers.

> **Note** Transactions cannot be nested inside other `Effect`s directly —
always commit at a `Stm.commit` boundary.
*/
@module("effect/STM")
external commit: t<'a, 'e, 'r> => Effect.t<'a, 'e, 'r> = "commit"

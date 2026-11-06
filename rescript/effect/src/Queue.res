/**
ReScript bindings for `Queue<A>` — a concurrent, bounded or unbounded FIFO queue.

Bounded queues provide *backpressure* — `offer` suspends the calling fiber when
the queue is full, and `take` suspends when it is empty. No threads are blocked;
suspended fibers resume when capacity or items become available.

A queue is finished one of two ways: `end` lets readers drain what is buffered
and then stop, `shutdown` stops at once and discards it.

**Quick start**
```rescript
let q = Queue.bounded(10)->Effect.runSync
q->Queue.offer("hello")->Effect.runPromise
q->Queue.take->Effect.runPromise // "hello"
```
*/
type t<'a>

// ─── Constructors ────────────────────────────────────────────────────────

/** Creates a bounded queue with backpressure. `offer` suspends when `capacity` is reached. */
@module("effect/Queue")
external bounded: int => Effect.t<t<'a>, 'e, 'r> = "bounded"

/** Creates an unbounded queue — `offer` never suspends. May grow without limit. */
@module("effect/Queue")
external unbounded: unit => Effect.t<t<'a>, 'e, 'r> = "unbounded"

/** Creates a bounded queue with a *sliding* strategy — new items overwrite the oldest when full. */
@module("effect/Queue")
external sliding: int => Effect.t<t<'a>, 'e, 'r> = "sliding"

/** Creates a bounded queue with a *dropping* strategy — new items are silently dropped when full. */
@module("effect/Queue")
external dropping: int => Effect.t<t<'a>, 'e, 'r> = "dropping"

// ─── Operations ──────────────────────────────────────────────────────────

/**
Enqueues a single item. For bounded queues, suspends the fiber until space is available.

Returns `false` when the queue is already done.
*/
@module("effect/Queue")
external offer: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "offer"

/** Enqueues all items. Returns the items that were not added (the queue was done, or a strategy dropped them). */
@module("effect/Queue")
external offerAll: (t<'a>, array<'a>) => Effect.t<array<'a>, 'e, 'r> = "offerAll"

/** Dequeues and returns the next item. Suspends the fiber until an item is available. */
@module("effect/Queue")
external take: t<'a> => Effect.t<'a, 'e, 'r> = "take"

/** Dequeues every item currently buffered. Suspends until there is at least one. */
@module("effect/Queue")
external takeAll: t<'a> => Effect.t<array<'a>, 'e, 'r> = "takeAll"

// ─── Inspection ──────────────────────────────────────────────────────────

/** Returns the current number of items in the queue (non-suspending). */
@module("effect/Queue")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"

/** Returns `true` if the queue is at capacity (non-suspending). Always `false` for unbounded queues. */
@module("effect/Queue")
external isFull: t<'a> => Effect.t<bool, 'e, 'r> = "isFull"

// ─── Lifecycle ───────────────────────────────────────────────────────────

/**
Ends the queue: no more items are accepted, and readers drain what is buffered
before they stop. A `Stream.fromQueue` over it ends cleanly.

Yields `false` when the queue was already done.

> **Note** `end` is a reserved word in ReScript — use `end_` here.
*/
@module("effect/Queue")
external end_: t<'a> => Effect.t<bool, 'e, 'r> = "end"

/** `end_` as a plain synchronous call, for callbacks that run outside an `Effect`. */
@module("effect/Queue")
external endUnsafe: t<'a> => bool = "endUnsafe"

/** Ends the queue with a failure, which readers see once they have drained what is buffered. */
@module("effect/Queue")
external fail: (t<'a>, 'e) => Effect.t<bool, 'e2, 'r> = "fail"

/**
Shuts the queue down at once, **discarding** buffered items and resuming pending
operations. To let readers finish what is buffered, use `end_`.

Yields `false` when the queue was already done.
*/
@module("effect/Queue")
external shutdown: t<'a> => Effect.t<bool, 'e, 'r> = "shutdown"

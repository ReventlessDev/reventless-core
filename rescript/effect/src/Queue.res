/**
ReScript bindings for `Queue<A>` — a concurrent, bounded or unbounded FIFO queue.

Bounded queues provide *backpressure* — `offer` suspends the calling fiber when
the queue is full, and `take` suspends when it is empty. No threads are blocked;
suspended fibers resume when capacity or items become available.

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

Returns `true` when the item is successfully enqueued.
*/
@module("effect/Queue")
external offer: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "offer"

/** Enqueues all items atomically. Suspends if the queue is bounded and does not have enough space. */
@module("effect/Queue")
external offerAll: (t<'a>, array<'a>) => Effect.t<bool, 'e, 'r> = "offerAll"

/** Dequeues and returns the next item. Suspends the fiber until an item is available. */
@module("effect/Queue")
external take: t<'a> => Effect.t<'a, 'e, 'r> = "take"

/** Dequeues all currently available items without suspending. Returns an empty array if the queue is empty. */
@module("effect/Queue")
external takeAll: t<'a> => Effect.t<array<'a>, 'e, 'r> = "takeAll"

/** Dequeues up to `n` items without suspending. */
@module("effect/Queue")
external takeUpTo: (t<'a>, int) => Effect.t<array<'a>, 'e, 'r> = "takeUpTo"

// ─── Inspection ──────────────────────────────────────────────────────────

/** Returns the current number of items in the queue (non-suspending). */
@module("effect/Queue")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"

/** Returns `true` if the queue currently has no items (non-suspending). */
@module("effect/Queue")
external isEmpty: t<'a> => Effect.t<bool, 'e, 'r> = "isEmpty"

/** Returns `true` if the queue is at capacity (non-suspending). Always `false` for unbounded queues. */
@module("effect/Queue")
external isFull: t<'a> => Effect.t<bool, 'e, 'r> = "isFull"

// ─── Lifecycle ───────────────────────────────────────────────────────────

/**
Shuts down the queue.

All pending `offer` and `take` operations fail immediately.
Future `offer` and `take` calls also fail immediately.
This propagates interruption through any `Stream.fromQueue` or `Effect.forever` drain loop.
*/
@module("effect/Queue")
external shutdown: t<'a> => Effect.t<unit, 'e, 'r> = "shutdown"

/** Returns `true` if the queue has been shut down. */
@module("effect/Queue")
external isShutdown: t<'a> => Effect.t<bool, 'e, 'r> = "isShutdown"

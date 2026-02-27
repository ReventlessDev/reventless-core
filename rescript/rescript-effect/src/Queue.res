// ReScript bindings for Effect Queue
//
// Queue<A> is a concurrent, bounded or unbounded FIFO queue.
// Bounded queues provide backpressure — offer blocks when full,
// take blocks when empty. Both blocking operations suspend the
// calling fiber (no thread wasted).

type t<'a>

// ─── Constructors ────────────────────────────────────────────────────────

// Bounded queue with backpressure — offer blocks when capacity is reached
@module("effect") @scope("Queue")
external bounded: int => Effect.t<t<'a>, 'e, 'r> = "bounded"

// Unbounded queue — offer never blocks (may grow without limit)
@module("effect") @scope("Queue")
external unbounded: unit => Effect.t<t<'a>, 'e, 'r> = "unbounded"

// Bounded with sliding strategy — new items overwrite oldest when full
@module("effect") @scope("Queue")
external sliding: int => Effect.t<t<'a>, 'e, 'r> = "sliding"

// Bounded with dropping strategy — new items are dropped when full
@module("effect") @scope("Queue")
external dropping: int => Effect.t<t<'a>, 'e, 'r> = "dropping"

// ─── Operations ──────────────────────────────────────────────────────────

// Offer an item — blocks if bounded and full (returns true when enqueued)
@module("effect") @scope("Queue")
external offer: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "offer"

// Offer all items atomically
@module("effect") @scope("Queue")
external offerAll: (t<'a>, array<'a>) => Effect.t<bool, 'e, 'r> = "offerAll"

// Take one item — blocks if the queue is empty
@module("effect") @scope("Queue")
external take: t<'a> => Effect.t<'a, 'e, 'r> = "take"

// Take all available items without blocking (returns empty array if empty)
@module("effect") @scope("Queue")
external takeAll: t<'a> => Effect.t<array<'a>, 'e, 'r> = "takeAll"

// Take up to N items without blocking
@module("effect") @scope("Queue")
external takeUpTo: (t<'a>, int) => Effect.t<array<'a>, 'e, 'r> = "takeUpTo"

// ─── Inspection ──────────────────────────────────────────────────────────

// Current number of items in the queue
@module("effect") @scope("Queue")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"

// Whether the queue is empty (non-blocking)
@module("effect") @scope("Queue")
external isEmpty: t<'a> => Effect.t<bool, 'e, 'r> = "isEmpty"

// Whether the queue is full (non-blocking, always false for unbounded)
@module("effect") @scope("Queue")
external isFull: t<'a> => Effect.t<bool, 'e, 'r> = "isFull"

// ─── Lifecycle ───────────────────────────────────────────────────────────

// Shut down the queue — pending offers/takes fail, future offers/takes fail immediately
@module("effect") @scope("Queue")
external shutdown: t<'a> => Effect.t<unit, 'e, 'r> = "shutdown"

// Whether the queue has been shut down
@module("effect") @scope("Queue")
external isShutdown: t<'a> => Effect.t<bool, 'e, 'r> = "isShutdown"

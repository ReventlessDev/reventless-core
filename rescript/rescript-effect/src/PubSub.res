// ReScript bindings for Effect PubSub
//
// PubSub<A> is a broadcast hub. Each subscriber receives their own Queue
// with a view of every published message. When no subscribers are present,
// published messages are dropped.
//
// Use PubSub to replace InMemory_Bus — it provides per-subscriber backpressure
// and makes tests production-realistic (slow consumers block fast publishers).

type t<'a>

// ─── Constructors ────────────────────────────────────────────────────────

// Bounded — publish blocks when all subscribers' queues are full
@module("effect") @scope("PubSub")
external bounded: int => Effect.t<t<'a>, 'e, 'r> = "bounded"

// Unbounded — publish never blocks
@module("effect") @scope("PubSub")
external unbounded: unit => Effect.t<t<'a>, 'e, 'r> = "unbounded"

// Sliding — new items overwrite the oldest in each subscriber's queue when full
@module("effect") @scope("PubSub")
external sliding: int => Effect.t<t<'a>, 'e, 'r> = "sliding"

// Dropping — new items are dropped when any subscriber's queue is full
@module("effect") @scope("PubSub")
external dropping: int => Effect.t<t<'a>, 'e, 'r> = "dropping"

// ─── Publishing ──────────────────────────────────────────────────────────

// Publish a single item to all subscribers
@module("effect") @scope("PubSub")
external publish: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "publish"

// Publish all items atomically
@module("effect") @scope("PubSub")
external publishAll: (t<'a>, array<'a>) => Effect.t<bool, 'e, 'r> = "publishAll"

// ─── Subscribing ─────────────────────────────────────────────────────────

// Subscribe — returns a scoped Queue. The subscription is automatically
// removed when the enclosing Scope closes (use Effect.scoped to manage).
@module("effect") @scope("PubSub")
external subscribe: t<'a> => Effect.t<Queue.t<'a>, 'e, 'r> = "subscribe"

// ─── Inspection ──────────────────────────────────────────────────────────

// Number of active subscribers
@module("effect") @scope("PubSub")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"

// ─── Lifecycle ───────────────────────────────────────────────────────────

@module("effect") @scope("PubSub")
external shutdown: t<'a> => Effect.t<unit, 'e, 'r> = "shutdown"

@module("effect") @scope("PubSub")
external isShutdown: t<'a> => Effect.t<bool, 'e, 'r> = "isShutdown"

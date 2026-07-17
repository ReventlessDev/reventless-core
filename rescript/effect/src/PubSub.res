/**
ReScript bindings for `PubSub<A>` — a broadcast hub where each subscriber
receives a private `Queue` with a view of every published message.

When no subscribers are present, published messages are dropped.
When all subscriber queues are full (bounded), `publish` suspends the publisher.

**Typical pattern**
```rescript
let hub = PubSub.bounded(100)->Effect.runSync

// Subscriber
PubSub.subscribe(hub)
->Effect.flatMap(q => Queue.take(q)->Effect.forever)
->Effect.scoped
->Effect.fork
->Effect.runPromise

// Publisher
PubSub.publish(hub, event)->Effect.runPromise
```
*/
type t<'a>

// ─── Constructors ────────────────────────────────────────────────────────

/** Creates a bounded `PubSub` — `publish` suspends when all subscriber queues are full. */
@module("effect/PubSub")
external bounded: int => Effect.t<t<'a>, 'e, 'r> = "bounded"

/** Creates an unbounded `PubSub` — `publish` never suspends. May grow without limit. */
@module("effect/PubSub")
external unbounded: unit => Effect.t<t<'a>, 'e, 'r> = "unbounded"

/** Creates a `PubSub` with a *sliding* strategy — new messages overwrite the oldest in each subscriber's queue when full. */
@module("effect/PubSub")
external sliding: int => Effect.t<t<'a>, 'e, 'r> = "sliding"

/** Creates a `PubSub` with a *dropping* strategy — new messages are silently dropped when any subscriber's queue is full. */
@module("effect/PubSub")
external dropping: int => Effect.t<t<'a>, 'e, 'r> = "dropping"

// ─── Publishing ──────────────────────────────────────────────────────────

/**
Publishes a single message to all current subscribers.

Returns `true` if the message was delivered to at least one subscriber.
Suspends if bounded and any subscriber's queue is full.
*/
@module("effect/PubSub")
external publish: (t<'a>, 'a) => Effect.t<bool, 'e, 'r> = "publish"

/** Publishes all messages atomically to all current subscribers. */
@module("effect/PubSub")
external publishAll: (t<'a>, array<'a>) => Effect.t<bool, 'e, 'r> = "publishAll"

// ─── Subscribing ─────────────────────────────────────────────────────────

/**
Subscribes to the `PubSub`, returning a scoped `Queue`.

The subscription is automatically removed when the enclosing `Scope` closes.
Use `Effect.scoped` to manage the scope:

**Example**
```rescript
PubSub.subscribe(hub)
->Effect.flatMap(q => Queue.take(q))
->Effect.scoped
->Effect.runPromise
```
*/
@module("effect/PubSub")
external subscribe: t<'a> => Effect.t<Queue.t<'a>, 'e, 'r> = "subscribe"

// ─── Inspection ──────────────────────────────────────────────────────────

/** Returns the number of active subscribers. */
@module("effect/PubSub")
external size: t<'a> => Effect.t<int, 'e, 'r> = "size"

// ─── Lifecycle ───────────────────────────────────────────────────────────

/** Shuts down the `PubSub`. All subscriber queues are shut down and pending publishes fail. */
@module("effect/PubSub")
external shutdown: t<'a> => Effect.t<unit, 'e, 'r> = "shutdown"

/** Returns `true` if the `PubSub` has been shut down. */
@module("effect/PubSub")
external isShutdown: t<'a> => Effect.t<bool, 'e, 'r> = "isShutdown"

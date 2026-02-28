/**
ReScript bindings for `Latch` — a binary synchronization gate.

Fibers calling `await_` block until the latch is opened. Once opened,
all waiting fibers are released immediately, and future `await_` calls
pass through without blocking. Closing re-arms the gate.

`Latch.t` is a transparent alias of `Effect.latch`. Create a latch with
`Effect.makeLatch(false)` (closed) or `Effect.makeLatch(true)` (open).

**Example**
```rescript
let latch = Effect.makeLatch(false)->Effect.runSync

// Consumer — blocks until latch is opened
latch->Latch.await_->Effect.fork->Effect.runPromise

// Producer — opens after setup is complete
latch->Latch.open_->Effect.runPromise
```
*/
type t = Effect.latch

/**
Suspends the current fiber until the latch is opened.

> **Note** `await` is a reserved keyword in ReScript — use `await_` here.
`latch.await` in Effect is a getter property, accessed via `@get`.
*/
@get
external await_: t => Effect.t<unit, 'e, 'r> = "await"

/**
Opens the latch, releasing all currently waiting fibers immediately.

> **Note** `open` is a reserved word in ReScript — use `open_` here.
*/
@get
external open_: t => Effect.t<unit, 'e, 'r> = "open"

/** Closes the latch — future `await_` calls will block again. */
@get
external close: t => Effect.t<unit, 'e, 'r> = "close"

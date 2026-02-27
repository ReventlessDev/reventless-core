// ReScript bindings for Effect Latch
//
// A Latch is a binary synchronization gate. Fibers calling await block
// until the latch is opened. Once opened, all waiting fibers are released
// immediately, and future await calls pass through without blocking.
//
// Use Latch instead of the Output.apply timing race pattern where publishers
// must wait for subscribers to register before any messages are sent.
//
// Transparent alias of Effect.latch. Create via Effect.makeLatch(false).

type t = Effect.latch

// Block the current fiber until the latch is opened
// Note: latch.await is a getter property in Effect, accessed via @get
// Note: `await` is a reserved keyword in ReScript — use await_
@get
external await_: t => Effect.t<unit, 'e, 'r> = "await"

// Open the latch — releases all currently waiting fibers immediately.
// Note: `open` is a reserved word in ReScript; bind as open_
@get
external open_: t => Effect.t<unit, 'e, 'r> = "open"

// Close the latch — future await calls will block again
@get
external close: t => Effect.t<unit, 'e, 'r> = "close"

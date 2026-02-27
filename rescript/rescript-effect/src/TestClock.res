// ReScript bindings for Effect TestClock
//
// TestClock makes it easy to deterministically and efficiently test effects
// involving the passage of time. Instead of waiting for actual time to pass,
// sleep and methods implemented in terms of it schedule effects to take place
// at a given clock time. Users can adjust the clock time using adjust, and all
// effects scheduled to take place on or before that time will automatically be
// run in order.
//
// Typical test pattern:
//   1. Fork the effect under test (it will sleep waiting for time to advance)
//   2. Adjust the clock to trigger the sleeps
//   3. Join the forked fiber to get its result
//
// TestClock is activated by providing TestContext.testContext via Effect.provide.

// Accesses a TestClock instance in the context and increments the time by the
// specified duration, running any actions scheduled for on or before the new
// time in order.
@module("effect") @scope("TestClock")
external adjust: Duration.t => Effect.t<unit, 'e, 'r> = "adjust"

// Accesses the current time of a TestClock instance in the context in milliseconds.
// Note: currentTimeMillis is an Effect value (not a function).
@module("effect") @scope("TestClock")
external currentTimeMillis: Effect.t<int, 'e, 'r> = "currentTimeMillis"

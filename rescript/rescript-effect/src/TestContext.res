// ReScript bindings for Effect TestContext
//
// TestContext is a Layer that provides test versions of core services:
// - TestClock (virtual clock for deterministic time control)
// - TestRandom (deterministic random number generation)
// - TestConsole (capturing console output in tests)
//
// Usage:
//   let program = ... // your Effect that uses sleep / Schedule
//   let result = await Effect.provide(program, TestContext.testContext)->Effect.runPromise

// Abstract type for Effect Layers — opaque; use via Effect.provide.
type layer

// The TestContext layer — provides TestClock and other test services.
// Provide this to an Effect to enable TestClock.adjust, TestClock.currentTimeMillis, etc.
@module("effect") @scope("TestContext")
external testContext: layer = "TestContext"

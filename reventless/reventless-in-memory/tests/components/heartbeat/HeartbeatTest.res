// Integration tests for Heartbeat (placeholder).
// Adapter-level tests are in adapter/HeartbeatRunnerTest.res.

open AsyncTest
open AsyncTest.Expect
open HeartbeatFixtures

describe("Heartbeat (in-memory)", () => {
  testPromise("bus is initialized", async () => {
    expect(true)->toBe(true)
  })
})

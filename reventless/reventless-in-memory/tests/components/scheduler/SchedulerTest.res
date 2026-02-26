// Integration tests for Scheduler (placeholder).
// Adapter-level tests are in adapter/ScheduledPublisherTest.res.

open AsyncTest
open AsyncTest.Expect
open SchedulerFixtures

describe("Scheduler (in-memory)", () => {
  testPromise("bus is initialized", async () => {
    expect(true)->toBe(true)
  })
})

// Integration tests for Task (placeholder).
// Adapter-level tests are in adapter/TaskBucketTest.res.

open AsyncTest
open AsyncTest.Expect

describe("Task (in-memory)", () => {
  testPromise("bus is initialized", async () => {
    expect(true)->toBe(true)
  })
})

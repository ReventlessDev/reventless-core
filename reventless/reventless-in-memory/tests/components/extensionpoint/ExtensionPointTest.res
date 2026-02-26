// Integration tests for ExtensionPoint (placeholder).

open AsyncTest
open AsyncTest.Expect
open ExtensionPointFixtures

describe("ExtensionPoint (in-memory)", () => {
  testPromise("bus is initialized", async () => {
    expect(true)->toBe(true)
  })
})
